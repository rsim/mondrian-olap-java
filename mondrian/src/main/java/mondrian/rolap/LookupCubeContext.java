/*
// This software is subject to the terms of the Eclipse Public License v1.0
// Agreement, available at the following URL:
// http://www.eclipse.org/legal/epl-v10.html.
// You must accept the terms of that agreement to use this software.
//
// Copyright (C) 2026 eazyBI
// All Rights Reserved.
*/

package mondrian.rolap;

import mondrian.calc.Calc;
import mondrian.calc.DummyExp;
import mondrian.calc.ResultStyle;
import mondrian.calc.TupleCollections;
import mondrian.calc.TupleIterable;
import mondrian.calc.TupleList;
import mondrian.calc.impl.CacheCalc;
import mondrian.calc.impl.DelegatingTupleList;
import mondrian.calc.impl.GenericCalc;
import mondrian.calc.impl.ValueCalc;
import mondrian.mdx.ResolvedFunCall;
import mondrian.olap.Cube;
import mondrian.olap.Dimension;
import mondrian.olap.Evaluator;
import mondrian.olap.Exp;
import mondrian.olap.ExpCacheDescriptor;
import mondrian.olap.Formula;
import mondrian.olap.Hierarchy;
import mondrian.olap.Member;
import mondrian.olap.MondrianException;
import mondrian.olap.OlapElement;
import mondrian.olap.Parameter;
import mondrian.olap.Query;
import mondrian.olap.QueryAxis;
import mondrian.olap.QueryPart;
import mondrian.olap.ResultLimitExceededException;
import mondrian.olap.Role;
import mondrian.olap.SchemaReader;
import mondrian.olap.Util;
import mondrian.olap.fun.AbstractAggregateFunDef;
import mondrian.olap.fun.AggregateFunDef;
import mondrian.olap.fun.ParenthesesFunDef;
import mondrian.olap.type.MemberType;
import mondrian.olap.type.ScalarType;
import mondrian.olap.type.SetType;
import mondrian.resource.MondrianResource;
import mondrian.server.Execution;
import mondrian.server.StatementImpl;

import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.IdentityHashMap;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * State of the LookupCube function for one target cube within one query
 * execution.
 *
 * <p>The context owns a query and an evaluator root for the target cube. The
 * target evaluator uses the cell reader of the calling evaluator, so cell
 * requests of the target cube are loaded in the same batches as the cell
 * requests of the source query.
 *
 * <p>The context caches compiled expressions and the mapping of source
 * members to target members for the lifetime of the execution.
 */
class LookupCubeContext {
    /**
     * Maximum number of compiled expressions that are kept. Expressions that
     * are built from strings with member names can be different for every
     * cell, so the cache is bounded.
     */
    private static final int MAX_COMPILED_EXPRESSIONS = 1000;

    private static final int MAX_MAPPED_TUPLE_LISTS = 1000;

    /**
     * Maximum depth of calculated members that refer to other calculated
     * members on a mapped hierarchy.
     */
    private static final int MAX_CALCULATED_MEMBER_DEPTH = 10;

    private static final HierarchyPair MISSING_PAIR =
        new HierarchyPair(null, null);

    private final RolapCube targetCube;
    private final RolapConnection connection;
    private final Query targetQuery;
    private final LookupCubeEvaluatorRoot targetRoot;
    private final RolapEvaluator workEvaluator;
    private boolean workEvaluatorInUse;

    private final Map<String, RolapCubeHierarchy> targetHierarchies =
        new HashMap<String, RolapCubeHierarchy>();
    private final Map<String, Calc> compiledExpressions =
        new LinkedHashMap<String, Calc>(16, 0.75f, true) {
            protected boolean removeEldestEntry(
                Map.Entry<String, Calc> eldest)
            {
                return size() > MAX_COMPILED_EXPRESSIONS;
            }
        };
    private final Map<Cube, List<HierarchyPair>> commonHierarchyPairs =
        new HashMap<Cube, List<HierarchyPair>>();
    private final Map<Hierarchy, HierarchyPair> hierarchyPairs =
        new HashMap<Hierarchy, HierarchyPair>();
    private final Map<Member, Member> mappedMembers =
        new HashMap<Member, Member>();
    private final Map<Member, ExpCacheDescriptor> expansionDescriptors =
        new HashMap<Member, ExpCacheDescriptor>();
    private final Map<List<List<Member>>, Map<List<HierarchyPair>, Member[]>>
        mappedTupleLists =
            new IdentityHashMap<
                List<List<Member>>, Map<List<HierarchyPair>, Member[]>>();
    private final Map<List<Object>, Member[]> placeholders =
        new LinkedHashMap<List<Object>, Member[]>(16, 0.75f, true) {
            protected boolean removeEldestEntry(
                Map.Entry<List<Object>, Member[]> eldest)
            {
                return size() > MAX_MAPPED_TUPLE_LISTS;
            }
        };

    /**
     * Creates a LookupCubeContext.
     *
     * @param owner Root of the source query
     * @param targetCube Target cube
     */
    LookupCubeContext(RolapEvaluatorRoot owner, RolapCube targetCube) {
        this.targetCube = targetCube;
        this.connection = owner.connection;
        // An execution clears the thread-local segments only of the stars of
        // its own cube. Segments of the target star can remain from an
        // earlier query in this thread, and a cache flush does not clear them.
        if (!owner.cube.isVirtual()
            && targetCube.getStar() != owner.cube.getStar())
        {
            targetCube.clearCachedAggregations(true);
        }
        final LookupCubeStatement statement =
            new LookupCubeStatement(connection, owner.execution);
        this.targetQuery =
            new Query(
                statement,
                targetCube,
                new Formula[0],
                new QueryAxis[0],
                null,
                new QueryPart[0],
                new Parameter[0],
                false);
        final RolapResult result =
            owner instanceof RolapResult.RolapResultEvaluatorRoot
                ? ((RolapResult.RolapResultEvaluatorRoot) owner).result
                : null;
        this.targetRoot =
            new LookupCubeEvaluatorRoot(owner, result, statement, targetQuery);
        final RolapEvaluator slicerEvaluator = new RolapEvaluator(targetRoot);
        targetRoot.setSlicerEvaluator(slicerEvaluator);
        this.workEvaluator = slicerEvaluator.push();
        for (RolapHierarchy hierarchy : targetCube.getHierarchies()) {
            if (!hierarchy.getDimension().isMeasures()) {
                targetHierarchies.put(
                    hierarchy.getUniqueName(), (RolapCubeHierarchy) hierarchy);
            }
        }
    }

    /**
     * Finds a cube that the current role can access.
     *
     * @param schemaReader Schema reader of the source query
     * @param cubeName Cube name, optionally in brackets
     * @return Cube
     * @throws MondrianException if the cube does not exist or the role cannot
     * access it
     */
    static RolapCube findCube(SchemaReader schemaReader, String cubeName) {
        String name = cubeName == null ? "" : cubeName.trim();
        if (name.length() > 2
            && name.startsWith("[")
            && name.endsWith("]"))
        {
            name = name.substring(1, name.length() - 1);
        }
        // Cubes that the role cannot access are not returned, so the error
        // does not reveal whether such a cube exists.
        for (Cube cube : schemaReader.getCubes()) {
            if (Util.compareName(cube.getName(), name) == 0) {
                return (RolapCube) cube;
            }
        }
        throw MondrianResource.instance().MdxCubeNotFound.ex(cubeName);
    }

    void clearResultCache(boolean clearValidResult) {
        targetRoot.clearResultCache(clearValidResult);
    }

    /**
     * Evaluates an expression in the target cube.
     *
     * @param source Evaluator that calls LookupCube
     * @param expression MDX expression
     * @param mapAll Whether to map all hierarchies that exist in both cubes
     * @param hierarchies Hierarchies whose context is mapped, or null
     * @param dimensions Dimensions whose hierarchies' context is mapped, or
     * null
     * @return Value of the expression
     */
    Object evaluate(
        RolapEvaluator source,
        String expression,
        boolean mapAll,
        List<Hierarchy> hierarchies,
        List<Dimension> dimensions)
    {
        final Calc calc = getCompiledExpression(expression);
        final List<HierarchyPair> pairs =
            getHierarchyPairs(source, mapAll, hierarchies, dimensions);
        final boolean reuseWorkEvaluator = !workEvaluatorInUse;
        final RolapEvaluator target =
            reuseWorkEvaluator
                ? workEvaluator
                : targetRoot.getSlicerEvaluator().push();
        final int savepoint = target.savepoint();
        workEvaluatorInUse = true;
        try {
            target.setCellReader(source.cellReader);
            if (!pairs.isEmpty()) {
                applyContext(source, target, pairs);
            }
            return calc.evaluate(target);
        } finally {
            target.restore(savepoint);
            if (reuseWorkEvaluator) {
                workEvaluatorInUse = false;
            }
        }
    }

    private Calc getCompiledExpression(String expression) {
        Calc calc = compiledExpressions.get(expression);
        if (calc == null) {
            calc = compile(expression);
            compiledExpressions.put(expression, calc);
        }
        return calc;
    }

    private Calc compile(String expression) {
        try {
            final Exp parsed = connection.parseExpression(expression);
            final Exp resolved =
                targetQuery.createValidator().validate(parsed, false);
            if (resolved.getType() instanceof SetType) {
                throw error("expression must return a value, not a set");
            }
            return targetQuery.compileExpression(resolved, true, null);
        } catch (RuntimeException e) {
            // Query limits are not errors of the expression, and callers
            // recognize them by the root cause.
            if (isResultLimitExceeded(e)) {
                throw e;
            }
            // The message includes the cause, and the cause is not chained, so
            // that callers that show the root cause see the cube and the
            // expression too.
            throw error(
                "LookupCube failed to compile expression '" + expression
                + "' in cube '" + targetCube.getName() + "': "
                + rootMessage(e));
        }
    }

    private static boolean isResultLimitExceeded(Throwable e) {
        for (Throwable cause = e; cause != null; cause = cause.getCause()) {
            if (cause instanceof ResultLimitExceededException) {
                return true;
            }
            if (cause.getCause() == cause) {
                break;
            }
        }
        return false;
    }

    private static String rootMessage(Throwable e) {
        Throwable cause = e;
        while (cause.getCause() != null && cause.getCause() != cause) {
            cause = cause.getCause();
        }
        String message =
            cause.getMessage() != null ? cause.getMessage() : e.toString();
        for (String prefix : new String[] {"Mondrian Error:", "Internal error: "}) {
            if (message.startsWith(prefix)) {
                message = message.substring(prefix.length());
            }
        }
        return message;
    }

    /**
     * Creates an error that fails the query. Unlike evaluation exceptions,
     * which become the value of a cell, a wrong use of LookupCube should not
     * go unnoticed.
     */
    static MondrianException error(String message) {
        return new MondrianException(message);
    }

    // Hierarchy mapping

    private List<HierarchyPair> getHierarchyPairs(
        RolapEvaluator source,
        boolean mapAll,
        List<Hierarchy> hierarchies,
        List<Dimension> dimensions)
    {
        if (mapAll) {
            return getCommonHierarchyPairs(source.getCube());
        }
        if (hierarchies == null && dimensions == null) {
            return Collections.emptyList();
        }
        final List<HierarchyPair> pairs = new ArrayList<HierarchyPair>();
        if (hierarchies != null) {
            for (Hierarchy hierarchy : hierarchies) {
                final HierarchyPair pair = getHierarchyPair(source, hierarchy);
                if (pair == MISSING_PAIR) {
                    throw error(
                        "LookupCube cannot map hierarchy '"
                        + hierarchy.getUniqueName()
                        + "' because it does not exist in cube '"
                        + targetCube.getName() + "'");
                }
                pairs.add(pair);
            }
        }
        if (dimensions != null) {
            for (Dimension dimension : dimensions) {
                int found = 0;
                for (Hierarchy hierarchy : dimension.getHierarchies()) {
                    final HierarchyPair pair =
                        getHierarchyPair(source, hierarchy);
                    if (pair != MISSING_PAIR) {
                        pairs.add(pair);
                        found++;
                    }
                }
                if (found == 0) {
                    throw error(
                        "LookupCube cannot map dimension '"
                        + dimension.getUniqueName()
                        + "' because it does not exist in cube '"
                        + targetCube.getName() + "'");
                }
            }
        }
        return pairs;
    }

    private List<HierarchyPair> getCommonHierarchyPairs(RolapCube sourceCube) {
        List<HierarchyPair> pairs = commonHierarchyPairs.get(sourceCube);
        if (pairs == null) {
            pairs = new ArrayList<HierarchyPair>();
            for (RolapHierarchy hierarchy : sourceCube.getHierarchies()) {
                if (hierarchy.getDimension().isMeasures()) {
                    continue;
                }
                final RolapCubeHierarchy targetHierarchy =
                    targetHierarchies.get(hierarchy.getUniqueName());
                if (targetHierarchy != null) {
                    pairs.add(
                        new HierarchyPair(
                            (RolapCubeHierarchy) hierarchy, targetHierarchy));
                }
            }
            commonHierarchyPairs.put(sourceCube, pairs);
        }
        return pairs;
    }

    private HierarchyPair getHierarchyPair(
        RolapEvaluator source,
        Hierarchy hierarchy)
    {
        HierarchyPair pair = hierarchyPairs.get(hierarchy);
        if (pair == null) {
            if (hierarchy.getDimension().isMeasures()) {
                throw error(
                    "LookupCube cannot map the Measures hierarchy");
            }
            // Find the hierarchy of the evaluator's cube, so that its ordinal
            // matches the evaluator's context.
            RolapCubeHierarchy sourceHierarchy = null;
            for (RolapHierarchy h : source.getCube().getHierarchies()) {
                if (h.getUniqueName().equals(hierarchy.getUniqueName())) {
                    sourceHierarchy = (RolapCubeHierarchy) h;
                    break;
                }
            }
            if (sourceHierarchy == null) {
                throw error(
                    "LookupCube cannot map hierarchy '"
                    + hierarchy.getUniqueName()
                    + "' because it does not exist in cube '"
                    + source.getCube().getName() + "'");
            }
            final RolapCubeHierarchy targetHierarchy =
                targetHierarchies.get(hierarchy.getUniqueName());
            pair =
                targetHierarchy == null
                    ? MISSING_PAIR
                    : new HierarchyPair(sourceHierarchy, targetHierarchy);
            hierarchyPairs.put(hierarchy, pair);
        }
        return pair;
    }

    // Context mapping

    /**
     * Sets the context of the target evaluator from the context of the source
     * evaluator for the given hierarchies.
     */
    private void applyContext(
        RolapEvaluator source,
        RolapEvaluator target,
        List<HierarchyPair> pairs)
    {
        // Stored members are set first. Aggregated calculated members then
        // set the context of all hierarchies of their tuples, as they do when
        // they are evaluated. Compound slicers come last, because in the
        // source query they have the lowest solve order.
        Map<TupleList, List<HierarchyPair>> compoundSlicers = null;
        List<HierarchyPair> calculatedPairs = null;
        List<Member> calculatedMembers = null;
        for (HierarchyPair pair : pairs) {
            final Member member = source.getContext(pair.source);
            if (member instanceof RolapResult.CompoundSlicerRolapMember) {
                final TupleList tupleList =
                    ((RolapResult.CompoundSlicerRolapMember) member)
                        .getTupleList();
                if (compoundSlicers == null) {
                    compoundSlicers =
                        new IdentityHashMap<
                            TupleList, List<HierarchyPair>>();
                }
                List<HierarchyPair> slicerPairs =
                    compoundSlicers.get(tupleList);
                if (slicerPairs == null) {
                    slicerPairs = new ArrayList<HierarchyPair>();
                    compoundSlicers.put(tupleList, slicerPairs);
                }
                slicerPairs.add(pair);
            } else if (isMappedDirectly(member)) {
                target.setContext(mapMember(pair, member));
            } else {
                if (calculatedPairs == null) {
                    calculatedPairs = new ArrayList<HierarchyPair>();
                    calculatedMembers = new ArrayList<Member>();
                }
                calculatedPairs.add(pair);
                calculatedMembers.add(member);
            }
        }
        if (calculatedPairs != null) {
            for (int i = 0; i < calculatedPairs.size(); i++) {
                applyMember(
                    source, target, calculatedPairs.get(i), pairs,
                    calculatedMembers.get(i), 0);
            }
        }
        if (compoundSlicers != null) {
            for (Map.Entry<TupleList, List<HierarchyPair>> entry
                : compoundSlicers.entrySet())
            {
                applyTupleList(
                    target, entry.getKey(), entry.getValue(), null);
            }
        }
    }

    private static boolean isMappedDirectly(Member member) {
        return member.isAll()
            || !member.isCalculated()
            || member instanceof RolapHierarchy.LimitedRollupMember;
    }

    private void applyMember(
        RolapEvaluator source,
        RolapEvaluator target,
        HierarchyPair pair,
        List<HierarchyPair> pairs,
        Member member,
        int depth)
    {
        if (isMappedDirectly(member)) {
            target.setContext(mapMember(pair, member));
            return;
        }
        if (depth > MAX_CALCULATED_MEMBER_DEPTH) {
            throw unsupportedMember(pair, member);
        }
        final Exp expression = member.getExpression();
        if (expression != null && expression.getType() instanceof MemberType) {
            final Member result =
                (Member) evaluateCached(source, pair, member, expression);
            if (result == null || result.isNull()) {
                target.setContext(pair.target.getNullMember());
            } else {
                applyMember(source, target, pair, pairs, result, depth + 1);
            }
            return;
        }
        final List<Exp> sets = new ArrayList<Exp>();
        if (expression == null || !collectAggregateSets(expression, sets)) {
            throw unsupportedMember(pair, member);
        }
        final List<List<Member>> tupleList;
        if (sets.size() == 1 && sets.get(0).getType() instanceof SetType) {
            tupleList =
                (TupleList) evaluateCached(source, pair, member, sets.get(0));
        } else {
            tupleList = new ArrayList<List<Member>>();
            for (Exp set : sets) {
                tupleList.addAll(evaluateSet(source, pair, set));
            }
        }
        // An aggregated member sets the context of all hierarchies of its
        // tuples, so all mapped hierarchies of the tuples are used.
        applyTupleList(target, tupleList, pairs, pair);
    }

    /**
     * Collects the set arguments of a calculated member expression that is an
     * aggregation of members or sets, such as {@code Aggregate({...})},
     * {@code [Time].[2024] + [Time].[2025]} or a member reference.
     *
     * @return whether the expression is supported
     */
    private static boolean collectAggregateSets(Exp exp, List<Exp> sets) {
        if (exp instanceof ResolvedFunCall) {
            final ResolvedFunCall call = (ResolvedFunCall) exp;
            if (call.getFunDef() instanceof ParenthesesFunDef
                && call.getArgCount() == 1)
            {
                return collectAggregateSets(call.getArg(0), sets);
            }
            if (call.getFunDef() instanceof AggregateFunDef
                && call.getArgCount() == 1)
            {
                sets.add(call.getArg(0));
                return true;
            }
            if (call.getFunName().equals("+")) {
                for (Exp arg : call.getArgs()) {
                    if (!collectAggregateSets(arg, sets)) {
                        return false;
                    }
                }
                return true;
            }
        }
        if (exp.getType() instanceof MemberType) {
            sets.add(exp);
            return true;
        }
        return false;
    }

    /**
     * Evaluates a set or member expression of a calculated member in the
     * source context, using the source expression cache.
     */
    private Object evaluateCached(
        RolapEvaluator source,
        HierarchyPair pair,
        Member member,
        Exp exp)
    {
        // A calculated member is expanded from one expression only, so the
        // descriptor is keyed by the member.
        ExpCacheDescriptor descriptor = expansionDescriptors.get(member);
        if (descriptor == null) {
            final Calc calc =
                exp.getType() instanceof SetType
                    ? new SetAsListCalc(
                        exp,
                        source.root.getCompiled(
                            exp, false, ResultStyle.ITERABLE))
                    : source.root.getCompiled(exp, false, null);
            // A new key expression keeps the cached value apart from values
            // that other calculations cache for the same expression.
            descriptor =
                new ExpCacheDescriptor(
                    new DummyExp(exp.getType()), calc, source);
            expansionDescriptors.put(member, descriptor);
        }
        final int savepoint = source.savepoint();
        try {
            // The calculated member is evaluated with the default member of
            // its hierarchy, as when its value is calculated.
            source.setContext(source.root.defaultMembers[
                pair.source.getOrdinalInCube()]);
            return source.getCachedResult(descriptor);
        } finally {
            source.restore(savepoint);
        }
    }

    private List<List<Member>> evaluateSet(
        RolapEvaluator source,
        HierarchyPair pair,
        Exp exp)
    {
        if (exp.getType() instanceof MemberType) {
            final Calc calc = source.root.getCompiled(exp, false, null);
            final int savepoint = source.savepoint();
            try {
                source.setContext(source.root.defaultMembers[
                    pair.source.getOrdinalInCube()]);
                final Member result = (Member) calc.evaluate(source);
                return result == null
                    ? Collections.<List<Member>>emptyList()
                    : Collections.singletonList(
                        Collections.singletonList(result));
            } finally {
                source.restore(savepoint);
            }
        }
        final Calc calc =
            new SetAsListCalc(
                exp, source.root.getCompiled(exp, false, ResultStyle.ITERABLE));
        final int savepoint = source.savepoint();
        try {
            source.setContext(source.root.defaultMembers[
                pair.source.getOrdinalInCube()]);
            return (TupleList) calc.evaluate(source);
        } finally {
            source.restore(savepoint);
        }
    }

    /**
     * Maps a list of source tuples to the target cube and sets the context of
     * the target evaluator to them. A single tuple is set as the context; for
     * several tuples, placeholder members aggregate the tuples in the target
     * cube in the same way as a compound slicer.
     *
     * @param target Target evaluator
     * @param tupleList Source tuples
     * @param pairs Hierarchies that can be mapped
     * @param ownerPair Hierarchy of the calculated member that is expanded,
     * or null for a compound slicer
     */
    private void applyTupleList(
        RolapEvaluator target,
        List<List<Member>> tupleList,
        List<HierarchyPair> pairs,
        HierarchyPair ownerPair)
    {
        Map<List<HierarchyPair>, Member[]> mappedByPairs =
            mappedTupleLists.get(tupleList);
        if (mappedByPairs == null) {
            if (mappedTupleLists.size() >= MAX_MAPPED_TUPLE_LISTS) {
                mappedTupleLists.clear();
            }
            mappedByPairs = new HashMap<List<HierarchyPair>, Member[]>();
            mappedTupleLists.put(tupleList, mappedByPairs);
        }
        Member[] members = mappedByPairs.get(pairs);
        if (members == null) {
            members = mapTupleList(tupleList, pairs, ownerPair);
            mappedByPairs.put(pairs, members);
        }
        for (Member member : members) {
            target.setContext(member);
        }
    }

    private Member[] mapTupleList(
        List<List<Member>> tupleList,
        List<HierarchyPair> pairs,
        HierarchyPair ownerPair)
    {
        final Map<Hierarchy, HierarchyPair> pairBySource =
            new HashMap<Hierarchy, HierarchyPair>();
        for (HierarchyPair pair : pairs) {
            pairBySource.put(pair.source, pair);
        }
        final Set<List<Member>> mappedTuples =
            new LinkedHashSet<List<Member>>();
        List<RolapCubeHierarchy> targetHierarchyList = null;
        for (List<Member> tuple : tupleList) {
            final List<Member> mappedTuple = new ArrayList<Member>();
            final List<RolapCubeHierarchy> tupleHierarchies =
                new ArrayList<RolapCubeHierarchy>();
            boolean missing = false;
            for (Member member : tuple) {
                final HierarchyPair pair = pairBySource.get(member.getHierarchy());
                if (pair == null) {
                    continue;
                }
                if (member.isCalculated() && !member.isAll()) {
                    throw unsupportedMember(pair, member);
                }
                final Member mapped = mapMember(pair, member);
                if (mapped.isNull()) {
                    missing = true;
                }
                mappedTuple.add(mapped);
                tupleHierarchies.add(pair.target);
            }
            if (targetHierarchyList == null) {
                targetHierarchyList = tupleHierarchies;
            } else if (!targetHierarchyList.equals(tupleHierarchies)) {
                throw error(
                    "LookupCube cannot map tuples with different hierarchies "
                    + targetHierarchyList + " and " + tupleHierarchies);
            }
            // A member that does not exist in the target cube has no data
            // there, so its tuple does not contribute to the aggregation.
            if (!missing && !mappedTuple.isEmpty()) {
                mappedTuples.add(mappedTuple);
            }
        }
        if (mappedTuples.isEmpty()) {
            final List<Member> nullMembers = new ArrayList<Member>();
            if (targetHierarchyList != null) {
                for (RolapCubeHierarchy hierarchy : targetHierarchyList) {
                    nullMembers.add(hierarchy.getNullMember());
                }
            }
            if (nullMembers.isEmpty() && ownerPair != null) {
                nullMembers.add(ownerPair.target.getNullMember());
            }
            return nullMembers.toArray(new Member[nullMembers.size()]);
        }
        if (mappedTuples.size() == 1) {
            final List<Member> tuple = mappedTuples.iterator().next();
            return tuple.toArray(new Member[tuple.size()]);
        }
        final List<Object> key = new ArrayList<Object>(2);
        key.add(targetHierarchyList);
        key.add(new ArrayList<List<Member>>(mappedTuples));
        Member[] members = placeholders.get(key);
        if (members == null) {
            members =
                createPlaceholders(
                    targetHierarchyList,
                    new DelegatingTupleList(
                        targetHierarchyList.size(),
                        new ArrayList<List<Member>>(mappedTuples)));
            placeholders.put(key, members);
        }
        return members;
    }

    /**
     * Creates placeholder members, one for each hierarchy of the tuples, that
     * aggregate the tuples in the target cube. This follows how
     * {@link RolapResult} evaluates a compound slicer.
     */
    private Member[] createPlaceholders(
        List<RolapCubeHierarchy> hierarchies,
        TupleList tupleList)
    {
        final Member[] members = new Member[hierarchies.size()];
        final Set<Member> placeholderSet = new HashSet<Member>();
        final AggregateTuplesCalc aggregateCalc =
            new AggregateTuplesCalc(tupleList, placeholderSet);
        final DummyExp exp = new DummyExp(new ScalarType());
        final Calc calc =
            new CacheCalc(
                exp,
                new ExpCacheDescriptor(exp, aggregateCalc, workEvaluator));
        for (int i = 0; i < members.length; i++) {
            members[i] =
                new PlaceholderMember(
                    (RolapMember) hierarchies.get(i).getNullMember(),
                    calc,
                    tupleList);
            placeholderSet.add(members[i]);
        }
        return members;
    }

    /**
     * Maps a stored member to the target cube.
     *
     * @return Target member, or the null member if the member does not exist
     * in the target cube or the role cannot access it
     */
    private Member mapMember(HierarchyPair pair, Member member) {
        Member mapped = mappedMembers.get(member);
        if (mapped == null) {
            mapped = lookupMember(pair, member);
            mappedMembers.put(member, mapped);
        }
        return mapped;
    }

    private Member lookupMember(HierarchyPair pair, Member member) {
        final SchemaReader schemaReader = targetRoot.schemaReader;
        final RolapCubeHierarchy target = pair.target;
        if (member.isAll()) {
            // A role whose top level is below the All member gets its default
            // member, as in a query of the target cube.
            if (target.hasAll()
                && schemaReader.getRole().canAccess(target.getAllMember()))
            {
                return schemaReader.substitute(target.getAllMember());
            }
            return targetRoot.defaultMembers[target.getOrdinalInCube()];
        }
        if (member.isNull()) {
            return target.getNullMember();
        }
        if (member instanceof RolapHierarchy.LimitedRollupMember) {
            member = ((RolapHierarchy.LimitedRollupMember) member).member;
        }
        Member mapped = null;
        if (member instanceof RolapCubeMember
            && pair.isShared()
            && !((RolapLevel) member.getLevel()).isParentChild())
        {
            mapped =
                target.lookupCubeMember(
                    ((RolapCubeMember) member).getRolapMember());
        }
        if (mapped == null) {
            mapped =
                schemaReader.getMemberByUniqueName(
                    Util.parseIdentifier(member.getUniqueName()), false);
        }
        final Role role = schemaReader.getRole();
        if (mapped == null || !role.canAccess(mapped)) {
            return target.getNullMember();
        }
        return schemaReader.substitute(mapped);
    }

    private MondrianException unsupportedMember(
        HierarchyPair pair,
        Member member)
    {
        return error(
            "LookupCube cannot map calculated member '"
            + member.getUniqueName() + "' of hierarchy '"
            + pair.source.getUniqueName()
            + "' to cube '" + targetCube.getName()
            + "'. Only members that aggregate members or sets are supported.");
    }

    /**
     * Placeholder member that aggregates mapped tuples.
     *
     * <p>All placeholders of a hierarchy wrap its null member, so they have the
     * same unique name. They are equal only to themselves, otherwise the
     * expression cache would return the value of one placeholder for another.
     */
    private static class PlaceholderMember
        extends RolapResult.CompoundSlicerRolapMember
    {
        PlaceholderMember(
            RolapMember nullMember,
            Calc calc,
            TupleList tupleList)
        {
            super(nullMember, calc, null, tupleList);
        }

        public boolean equals(Object o) {
            return o == this;
        }

        public boolean equals(OlapElement o) {
            return o == this;
        }

        public int hashCode() {
            return System.identityHashCode(this);
        }
    }

    /**
     * Pair of a source cube hierarchy and the target cube hierarchy with the
     * same unique name.
     */
    private static class HierarchyPair {
        final RolapCubeHierarchy source;
        final RolapCubeHierarchy target;

        HierarchyPair(RolapCubeHierarchy source, RolapCubeHierarchy target) {
            this.source = source;
            this.target = target;
        }

        boolean isShared() {
            return source.getRolapHierarchy() == target.getRolapHierarchy();
        }
    }

    /**
     * Evaluates a set expression and materializes it as a list, so that the
     * result can be cached and iterated more than once.
     */
    private static class SetAsListCalc extends GenericCalc {
        private final Calc setCalc;

        SetAsListCalc(Exp exp, Calc setCalc) {
            super(exp, new Calc[] {setCalc});
            this.setCalc = setCalc;
        }

        public Object evaluate(Evaluator evaluator) {
            final Object value = setCalc.evaluate(evaluator);
            if (value instanceof TupleList) {
                return value;
            }
            return TupleCollections.materialize((TupleIterable) value, false);
        }
    }

    /**
     * Aggregates the current measure over the mapped tuples. Like the
     * compound slicer calculation of {@link RolapResult}, it leaves out the
     * hierarchies whose placeholder member was replaced by the expression.
     */
    private static class AggregateTuplesCalc extends GenericCalc {
        private final TupleList tupleList;
        private final Set<Member> placeholders;
        private final Calc valueCalc =
            new ValueCalc(new DummyExp(new ScalarType()));

        AggregateTuplesCalc(TupleList tupleList, Set<Member> placeholders) {
            super(new DummyExp(new ScalarType()), new Calc[0]);
            this.tupleList = tupleList;
            this.placeholders = placeholders;
        }

        public Object evaluate(Evaluator evaluator) {
            final TupleList list =
                AbstractAggregateFunDef.processUnrelatedDimensions(
                    activeTuples((RolapEvaluator) evaluator), evaluator);
            return AggregateFunDef.AggregateCalc.aggregate(
                valueCalc, evaluator, list);
        }

        private TupleList activeTuples(RolapEvaluator evaluator) {
            final List<Member> first = tupleList.get(0);
            final boolean[] keep = new boolean[first.size()];
            int keepCount = 0;
            final Member expanding = evaluator.getExpanding();
            for (int i = 0; i < keep.length; i++) {
                final Hierarchy hierarchy = first.get(i).getHierarchy();
                keep[i] =
                    placeholders.contains(evaluator.getContext(hierarchy))
                    || (expanding != null
                        && placeholders.contains(expanding)
                        && expanding.getHierarchy().equals(hierarchy));
                if (keep[i]) {
                    keepCount++;
                }
            }
            if (keepCount == keep.length) {
                return tupleList;
            }
            final Set<List<Member>> tuples =
                new LinkedHashSet<List<Member>>();
            for (List<Member> tuple : tupleList) {
                final List<Member> projected =
                    new ArrayList<Member>(keepCount);
                for (int i = 0; i < keep.length; i++) {
                    if (keep[i]) {
                        projected.add(tuple.get(i));
                    }
                }
                tuples.add(projected);
            }
            return new DelegatingTupleList(
                keepCount, new ArrayList<List<Member>>(tuples));
        }

        public boolean dependsOn(Hierarchy hierarchy) {
            return true;
        }
    }

    /**
     * Statement of the target cube query. It is not registered with the
     * server; it belongs to the execution of the source query.
     */
    private static class LookupCubeStatement extends StatementImpl {
        private final RolapConnection connection;
        private final Execution execution;

        LookupCubeStatement(RolapConnection connection, Execution execution) {
            this.connection = connection;
            this.execution = execution;
        }

        public RolapConnection getMondrianConnection() {
            return connection;
        }

        @Override
        public Execution getCurrentExecution() {
            return execution;
        }

        public void close() {
        }
    }
}

// End LookupCubeContext.java
