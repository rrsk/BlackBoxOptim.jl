"""
  Borg MOEA algorithm.

  Based on Hadka & Reed, "Borg: An Auto-Adaptive Many-Objective Evolutionary Computing
  Framework", Evol. Comp. 2013
"""
type BorgMOEA{FS<:FitnessScheme,V<:Evaluator,P<:Population,M<:GeneticOperator,E<:EmbeddingOperator} <: SteppingOptimizer
  evaluator::V
  population::P     # candidates, NOTE index one is always reserved for one archive parent for recombination
  rand_check_order::Vector{Int} # random population check order

  n_restarts::Int
  n_steps::Int
  last_restart_check::Int
  last_wrecombinate_update::Int

  τ::Float64        # tournament size, fraction of the population
  γ::Float64        # recommended population-to-archive ratio
  γ_δ::Float64      # the maximum allowed deviation of the population-to-archive ratio from γ
  min_popsize::Int  # the minimal population size

  recombinate_distr::Categorical # weights of the recombination operators

  # method parameters
  ζ::Float64        # dampening coefficient for recombination operator weights
  wrecombinate_update_period::Int
  restart_check_period::Int
  max_steps_without_ϵ_progress::Int

  recombinate::Vector{CrossoverOperator} # recombination operators

  # Set of operators that together define a specific DE strategy.
  select::TournamentSelector{HatCompare{FS}}         # random individuals selector
  modify::M         # genetic operator
  embed::E          # embedding operator

  function Base.call{O<:OptimizationProblem, P<:Population,
                     M<:GeneticOperator, E<:EmbeddingOperator}(
        ::Type{BorgMOEA}, problem::O,
        pop::P, recombinate::Vector{CrossoverOperator},
        modify::M = M(), embed::E = E(), params = EMPTY_PARAMS)
    # NOTE if ϵ-dominance is used, params[:ϵ] has the priority
    fit_scheme = fitness_scheme(problem)
    isa(fit_scheme, TupleFitnessScheme) || throw(ArgumentError("BorgMOEA can only solve problems with `TupleFitnessScheme`"))
    !isempty(recombinate) || throw(ArgumentError("No recombinate operators specified"))
    fit_scheme = convert(EpsBoxDominanceFitnessScheme, fit_scheme, params[:ϵ])
    archive = EpsBoxArchive(fit_scheme, params)
    evaluator = ProblemEvaluator(problem, archive)
    new{typeof(fit_scheme),typeof(evaluator),P,M,E}(evaluator, pop, Vector{Int}(), 0, 0, 0, 0,
           params[:τ], params[:γ], params[:γ_δ], params[:PopulationSize],
           Categorical(ones(length(recombinate))/length(recombinate)),
           params[:ζ], params[:OperatorsUpdatePeriod], params[:RestartCheckPeriod],
           params[:MaxStepsWithoutProgress],
           recombinate,
           TournamentSelector(fit_scheme, ceil(Int, params[:τ]*popsize(pop))), modify, embed)
  end
end

const BorgMOEA_DefaultParameters = chain(EpsBoxArchive_DefaultParameters, ParamsDict(
  :ϵ => 0.1,        # size of the ϵ-box
  :τ => 0.02,       # selection ratio, fraction of population to use for tournament
  :γ => 4.0,        # recommended population-to-archive ratio
  :γ_δ => 0.25,     # the maximum allowed deviation of the population-to-archive ratio from γ
  :ζ => 1.0,        # dampening coefficient for recombination operator weights
  :RestartCheckPeriod => 1000,
  :OperatorsUpdatePeriod => 100,
  :MaxStepsWithoutProgress => 100
))

function borg_moea{FS<:TupleFitnessScheme}(problem::OptimizationProblem{FS}, options::Parameters = EMPTY_PARAMS)
  opts = chain(BorgMOEA_DefaultParameters, options)
  fs = fitness_scheme(problem)
  N = numobjectives(fs)
  F = fitness_eltype(fs)
  pop = population(problem, opts, nafitness(IndexedTupleFitness{N,F}), ntransient=1)
  BorgMOEA(problem, pop, CrossoverOperator[DiffEvoRandBin1(chain(DE_DefaultOptions, options)),
                                           SimulatedBinaryCrossover(chain(SBX_DefaultOptions, options)),
                                           SimplexCrossover{3}(chain(SPX_DefaultOptions, options)),
                                           ParentCentricCrossover{2}(chain(PCX_DefaultOptions, options)),
                                           ParentCentricCrossover{3}(chain(PCX_DefaultOptions, options)),
                                           UnimodalNormalDistributionCrossover{2}(chain(UNDX_DefaultOptions, options)),
                                           UnimodalNormalDistributionCrossover{3}(chain(UNDX_DefaultOptions, options))],
           MutationClock(SimpleGibbsMutation(search_space(problem)), 0.25),
           RandomBound(search_space(problem)), opts)
end

archive(alg::BorgMOEA) = alg.evaluator.archive

# Take one step of Borg MOEA.
function step!(alg::BorgMOEA)
    alg.n_steps += 1
    if alg.n_steps >= alg.last_restart_check + alg.restart_check_period
        # check for restarting conditions
        if (!isempty(archive(alg)) &&
            (abs(popsize(alg.population) - alg.γ * length(archive(alg))) >= alg.γ_δ * length(archive(alg)))) ||
            candidates_without_progress(archive(alg)) >=  alg.max_steps_without_ϵ_progress
            restart!(alg)
        end
    end
    if alg.n_steps >= alg.last_wrecombinate_update + alg.wrecombinate_update_period
        update_recombination_weights!(alg)
    end
    # Select the operators to apply based on their probabilities
    recomb_op_ix = rand(alg.recombinate_distr)
    recomb_op = alg.recombinate[recomb_op_ix]
    # select parents for recombination
    n_parents = numparents(recomb_op)
    # parent indices
    parent_indices = select(alg.select, alg.population,
                            isempty(archive(alg)) ? n_parents : n_parents-1)
    if !isempty(archive(alg))
        # get one parent from the archive and copy it to the fitrst transient member
        arch_ix = transient_range(alg.population)[1]
        alg.population[arch_ix] = archive(alg)[sample(1:length(archive(alg)))]
        push!(parent_indices, arch_ix)
    end
    # Crossover parents and target
    children = [acquire_candi(alg.population) for i in 1:numchildren(recomb_op)]
    apply!(recomb_op, Individual[child.params for child in children], zeros(Int, length(children)), alg.population, parent_indices)
    for child in children
        process_candidate!(alg, child, recomb_op_ix, parent_indices[1])
    end

    return alg
end

function process_candidate!(alg::BorgMOEA, candi::Candidate, recomb_op_ix::Int, ref_index::Int)
    apply!(alg.embed, candi.params, alg.population, ref_index)
    reset_fitness!(candi, alg.population)
    candi.op = alg.recombinate[recomb_op_ix]
    candi.tag = recomb_op_ix
    ifitness = fitness(update_fitness!(alg.evaluator, candi)) # implicitly updates the archive
    # test the population
    hat_comp = HatCompare(fitness_scheme(archive(alg)))
    popsz = popsize(alg.population)
    if length(alg.rand_check_order) != popsz
        # initialize the random check order
        alg.rand_check_order = randperm(popsz)
    end
    comp = 0
    isaccepted = false
    # iterate through the population in a random way
    for i in 1:popsz
        # use "modern" Fisher-Yates shuffle to gen random population index
        j = rand(i:popsz)
        ix = alg.rand_check_order[j] # the next random individual
        if j > i
            alg.rand_check_order[j] = alg.rand_check_order[i]
            alg.rand_check_order[i] = ix
        end
        cur_comp = hat_comp(ifitness, fitness(alg.population, ix))[1]
        if cur_comp > 0 # new candidate does not dominate
            comp = cur_comp
            break
        elseif cur_comp < 0 # replace the first dominated
            comp = cur_comp
            candi.index = ix
            isaccepted = true
            # FIXME the population check is stopped when the first candidate dominated
            # by the `child` is found, but since the population might already contain candidates
            # dominated by others , it could be that the `child` is also dominated
            # In Borg paper they do not discuss this situation in detail -- whether the search
            # should continue
            break
        end
    end
    if comp == 0 # non-dominating candidate, replace random individual in the population
        candi.index = rand(1:popsz) # replace the random non-dominated
        isaccepted = true
    end
    if isaccepted
        accept_candi!(alg.population, candi)
    else
        release_candi(alg.population, candi)
    end
end

# trace current optimization state,
# Called by OptRunController trace_progress()
function trace_state(io::IO, alg::BorgMOEA)
    println(io, "pop.size=", popsize(alg.population),
                " arch.size=", length(archive(alg)),
                " recombinate=", alg.recombinate_distr,
                " N_restarts=", alg.n_restarts)
end

"""
  Update recombination operator probabilities based on the archive tag counts.
"""
function update_recombination_weights!(alg::BorgMOEA)
    op_counts = tagcounts(archive(alg))
    adj_op_counts = sum(values(op_counts)) + length(alg.recombinate)*alg.ζ
    alg.recombinate_distr = Categorical([(get(op_counts, i, 0)+alg.ζ)/adj_op_counts for i in eachindex(alg.recombinate)])
    alg.last_wrecombinate_update = alg.n_steps
    return alg
end

"""
    Restart Borg MOEA.

    Resize and refills the population from the archive.
"""
function restart!(alg::BorgMOEA)
    narchived = length(archive(alg))
    new_popsize = max(alg.min_popsize, ceil(Int, alg.γ * narchived))
    # fill populations with the solutions from the archive
    resize!(alg.population, new_popsize)
    i = 1 # current candidate index
    while i <= min(narchived, new_popsize)
        alg.population[i] = archive(alg)[i]
        i += 1
    end
    # inject mutated archive members
    while i <= new_popsize
        mut_archived = acquire_candi(alg.population)
        mut_archived.index = i
        copy!(mut_archived.params, params(archive(alg)[rand(1:narchived)]))
        reset_fitness!(mut_archived, alg.population)
        apply!(alg.modify, mut_archived.params, i)
        # project using one unmodified from the archive as the reference
        apply!(alg.embed, mut_archived.params, alg.population, rand(1:narchived))
        accept_candi!(alg.population, mut_archived)
        i += 1
    end
    alg.select.size = max(2, floor(Int, alg.τ * new_popsize))
    archive(alg).candidates_without_progress = 0
    alg.last_restart_check = alg.n_steps
    alg.n_restarts+=1
    return alg
end
