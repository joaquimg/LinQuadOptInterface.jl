#=
    The Objective Sense
=#

MOI.supports(::LinQuadOptimizer, ::MOI.ObjectiveSense) = true

MOI.get(model::LinQuadOptimizer,::MOI.ObjectiveSense) = model.obj_sense
function MOI.set(model::LinQuadOptimizer, ::MOI.ObjectiveSense,
                  sense::MOI.OptimizationSense)
    if sense == MOI.MIN_SENSE
        change_objective_sense!(model, :min)
        model.obj_sense = MOI.MIN_SENSE
    elseif sense == MOI.MAX_SENSE
        change_objective_sense!(model, :max)
        model.obj_sense = MOI.MAX_SENSE
    elseif sense == MOI.FEASIBILITY_SENSE
        # we set the objective sense to :min, and the objective to 0.0
        change_objective_sense!(model, :min)
        unsafe_set!(model, MOI.ObjectiveFunction{Linear}(),
                    MOI.ScalarAffineFunction(MOI.ScalarAffineTerm{Float64}[],
                    0.0))
        model.obj_type = AFFINE_OBJECTIVE
        model.obj_sense = MOI.FEASIBILITY_SENSE
    else
        throw(MOI.CannotSetAttribute(MOI.ObjectiveSense,
                                     "ObjectiveSense $(sense) not recognised."))
    end
end

#=
    The Objective Function
=#

function __assert_objective__(model::LinQuadOptimizer,
                              attribute::MOI.ObjectiveFunction{F}) where F
    if MOI.get(model, MOI.ObjectiveSense()) == MOI.FEASIBILITY_SENSE
        # it doesn't make sense to set an objective for a feasibility problem
        throw(MOI.CannotSetAttribute(attribute, "Cannot set $(attribute) when" *
            " MOI.ObjectiveSense is MOI.FEASIBILITY_SENSE."))
    elseif !(F in supported_objectives(model))
        throw(MOI.UnsupportedAttribute(attribute))
    end
end

function MOI.set(model::LinQuadOptimizer,
                  attribute::MOI.ObjectiveFunction{MOI.SingleVariable},
                  objective::MOI.SingleVariable)
     __assert_objective__(model, attribute)
    if model.obj_type == QUADRATIC_OBJECTIVE
        set_quadratic_objective!(model, Int[], Int[], Float64[])
    end
    model.obj_type = SINGLE_VARIABLE_OBJECTIVE
    model.single_obj_var = objective.variable
    set_linear_objective!(model, [get_column(model, objective.variable)], [1.0])
    set_constant_objective!(model, 0.0)
end

function MOI.set(model::LinQuadOptimizer, attribute::MOI.ObjectiveFunction{F},
                  objective::Linear) where F
    __assert_objective__(model, attribute)
    unsafe_set!(model, MOI.ObjectiveFunction{Linear}(), MOIU.canonical(objective))
end

"""
    unsafe_set!(m, ::MOI.ObjectiveFunction{F}, objective::Linear) where F

Sets a linear objective function without cannonicalizing `objective`.
"""
function unsafe_set!(model::LinQuadOptimizer, ::MOI.ObjectiveFunction{F},
                     objective::Linear) where F
    if model.obj_type == QUADRATIC_OBJECTIVE
        # previous objective was quadratic, so zero quadratic part
        set_quadratic_objective!(model, Int[], Int[], Float64[])
    end
    model.obj_type = AFFINE_OBJECTIVE
    model.single_obj_var = nothing
    set_linear_objective!(model,
        map(term -> get_column(model, term.variable_index), objective.terms),
        map(term -> term.coefficient, objective.terms)
    )
    set_constant_objective!(model, objective.constant)
end

function MOI.set(model::LinQuadOptimizer, attribute::MOI.ObjectiveFunction,
                  objective::Quad)
    __assert_objective__(model, attribute)
    model.obj_type = QUADRATIC_OBJECTIVE
    model.single_obj_var = nothing
    aff_cols, aff_coefs, quad_rows, quad_cols, quad_coefs = canonical_reduction(model, objective)
    set_linear_objective!(model, aff_cols, aff_coefs)
    set_quadratic_objective!(model, quad_rows, quad_cols, quad_coefs)
    set_constant_objective!(model, objective.constant)
end

#=
    Get the objective function
=#
function MOI.supports(model::LinQuadOptimizer, ::MOI.ObjectiveFunction{F}) where F
    return F in supported_objectives(model)
end

function MOI.get(model::LinQuadOptimizer, ::MOI.ObjectiveFunctionType)
    if model.obj_type == SINGLE_VARIABLE_OBJECTIVE
        return MOI.SingleVariable
    elseif model.obj_type == AFFINE_OBJECTIVE
        return MOI.ScalarAffineFunction{Float64}
    else
        @assert model.obj_type == QUADRATIC_OBJECTIVE
        return MOI.ScalarQuadraticFunction{Float64}
    end
end

function MOI.get(model::LinQuadOptimizer, ::MOI.ObjectiveFunction{MOI.SingleVariable})
    if model.obj_type != SINGLE_VARIABLE_OBJECTIVE
        throw(InexactError(:convert, SINGLE_VARIABLE_OBJECTIVE, model.obj_type))
    end
    return MOI.SingleVariable(model.single_obj_var::MOI.VariableIndex)
end

function MOI.get(model::LinQuadOptimizer, ::MOI.ObjectiveFunction{Linear})
    if model.obj_type == QUADRATIC_OBJECTIVE
        throw(InexactError(:convert, AFFINE_OBJECTIVE, model.obj_type))
    end
    variable_coefficients = zeros(length(model.variable_references))
    get_linear_objective!(model, variable_coefficients)
    terms = map(
        (variable, coefficient) -> MOI.ScalarAffineTerm{Float64}(coefficient, variable),
        model.variable_references,
        variable_coefficients
    )
    return Linear(terms, get_constant_objective(model))
end

function MOI.get(model::LinQuadOptimizer, ::MOI.ObjectiveFunction{Quad})
    variable_coefficients = zeros(length(model.variable_references))
    get_linear_objective!(model, variable_coefficients)
    affine_terms = map(
        (variable, coefficient) -> MOI.ScalarAffineTerm{Float64}(coefficient, variable),
        model.variable_references,
        variable_coefficients
    )
    quadratic_terms = MOI.ScalarQuadraticTerm{Float64}[]
    if model.obj_type == QUADRATIC_OBJECTIVE
        Q = get_quadratic_terms_objective(model)
        rows = rowvals(Q)
        coefficients = nonzeros(Q)
        sizehint!(quadratic_terms, length(coefficients))
        for (column, variable) in enumerate(model.variable_references)
            for j in nzrange(Q, column)
                row = rows[j]
                push!(quadratic_terms,
                      MOI.ScalarQuadraticTerm{Float64}(
                          coefficients[j],
                          model.variable_references[row],
                          variable)
                )
            end
        end
    end
    return Quad(affine_terms, quadratic_terms, get_constant_objective(model))
end

#=
    Modify objective function
=#

function MOI.modify(model::LinQuadOptimizer, ::MOI.ObjectiveFunction{F},
                     change::MOI.ScalarCoefficientChange{Float64}) where F<:MOI.AbstractScalarFunction
    if F <: MOI.ScalarQuadraticFunction && model.obj_type != QUADRATIC_OBJECTIVE
        throw(MOI.UnsupportedObjectiveModification(change,
            "ObjectiveFunction is not a ScalarQuadraticFunction."))
    elseif F <: MOI.ScalarAffineFunction && model.obj_type != AFFINE_OBJECTIVE
        throw(MOI.UnsupportedObjectiveModification(change,
            "ObjectiveFunction is not a ScalarAffineFunction."))
    end
    if model.obj_type == SINGLE_VARIABLE_OBJECTIVE
        model.obj_type = AFFINE_OBJECTIVE
        model.single_obj_var = nothing
    end
    change_objective_coefficient!(model, get_column(model, change.variable),
                                  change.new_coefficient)
end

function MOI.modify(model::LinQuadOptimizer, ::MOI.ObjectiveFunction{F},
                     change::MOI.ScalarConstantChange{Float64}) where F<:MOI.AbstractScalarFunction
    if F == MOI.SingleVariable
        throw(MOI.UnsupportedObjectiveModification(change,
            "ObjectiveFunction is a SingleVariable. Cannot change constant term."))
    end
    set_constant_objective!(model, change.new_constant)
end
