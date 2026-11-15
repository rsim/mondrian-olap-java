/*
// This software is subject to the terms of the Eclipse Public License v1.0
// Agreement, available at the following URL:
// http://www.eclipse.org/legal/epl-v10.html.
// You must accept the terms of that agreement to use this software.
//
// Copyright (C) 2026 eazyBI
// All Rights Reserved.
*/

package mondrian.olap.fun;

import mondrian.calc.Calc;
import mondrian.calc.DimensionCalc;
import mondrian.calc.ExpCompiler;
import mondrian.calc.HierarchyCalc;
import mondrian.calc.StringCalc;
import mondrian.calc.impl.GenericCalc;
import mondrian.mdx.MdxVisitorImpl;
import mondrian.mdx.MemberExpr;
import mondrian.mdx.NamedSetExpr;
import mondrian.mdx.ResolvedFunCall;
import mondrian.olap.Category;
import mondrian.olap.Dimension;
import mondrian.olap.Evaluator;
import mondrian.olap.Exp;
import mondrian.olap.Formula;
import mondrian.olap.FunDef;
import mondrian.olap.Hierarchy;
import mondrian.olap.Literal;
import mondrian.olap.Member;
import mondrian.olap.NamedSet;
import mondrian.olap.Query;
import mondrian.olap.QueryAxis;
import mondrian.olap.Syntax;
import mondrian.olap.Validator;
import mondrian.olap.type.MemberType;
import mondrian.olap.type.SetType;
import mondrian.olap.type.TupleType;
import mondrian.olap.type.Type;
import mondrian.rolap.RolapEvaluator;

import java.util.ArrayList;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/**
 * Definition of the <code>LookupCube</code> MDX function.
 *
 * <p>Syntax:
 * <blockquote><code>
 * LookupCube(&lt;Cube Name&gt;, &lt;Expression String&gt;)<br>
 * LookupCube(&lt;Cube Name&gt;, &lt;Expression String&gt;,
 * SHARED_CONTEXT)<br>
 * LookupCube(&lt;Cube Name&gt;, &lt;Expression String&gt;,
 * &lt;Dimension or Hierarchy&gt;[, ...])
 * </code></blockquote>
 *
 * <p>Evaluates an MDX expression, given as a string, in another cube of the
 * same schema and returns its value.
 *
 * <p>With two arguments the function has the semantics of the SQL Server
 * Analysis Services function: the current context is not carried over, so the
 * expression is evaluated in the default context of the other cube.
 *
 * <p>The optional arguments carry the current context over to the other cube.
 * <code>SHARED_CONTEXT</code> maps the current members of all hierarchies that
 * exist in both cubes. Dimensions and hierarchies map only the listed ones. Hierarchies
 * are matched by unique name.
 */
public class LookupCubeFunDef extends FunDefBase {
    static final ResolverImpl Resolver = new ResolverImpl();

    private static final String SHARED_CONTEXT = "SHARED_CONTEXT";

    private LookupCubeFunDef(FunDef dummyFunDef) {
        super(dummyFunDef);
    }

    public Calc compileCall(ResolvedFunCall call, ExpCompiler compiler) {
        final Exp[] args = call.getArgs();
        final List<Calc> calcList = new ArrayList<Calc>();
        final StringCalc cubeNameCalc = compiler.compileString(args[0]);
        final StringCalc expressionCalc = compiler.compileString(args[1]);
        calcList.add(cubeNameCalc);
        calcList.add(expressionCalc);
        boolean mapAll = false;
        final List<HierarchyCalc> hierarchyCalcs =
            new ArrayList<HierarchyCalc>();
        final List<DimensionCalc> dimensionCalcs =
            new ArrayList<DimensionCalc>();
        for (int i = 2; i < args.length; i++) {
            final int category = args[i].getCategory() & Category.Mask;
            if (category == Category.Dimension) {
                final DimensionCalc calc = compiler.compileDimension(args[i]);
                dimensionCalcs.add(calc);
                calcList.add(calc);
            } else if (category == Category.Hierarchy) {
                final HierarchyCalc calc = compiler.compileHierarchy(args[i]);
                hierarchyCalcs.add(calc);
                calcList.add(calc);
            } else {
                // The resolver accepts only the SHARED_CONTEXT symbol here.
                mapAll = true;
            }
        }
        return new LookupCubeCalc(
            call,
            calcList.toArray(new Calc[calcList.size()]),
            cubeNameCalc,
            expressionCalc,
            mapAll,
            hierarchyCalcs,
            dimensionCalcs);
    }

    /**
     * Returns whether the formulas, axes or slicer of a query call LookupCube,
     * directly or through calculated members and named sets.
     *
     * @param query Query
     * @return Whether the query uses LookupCube
     */
    public static boolean usesLookupCube(Query query) {
        final LookupCubeFinder finder = findInQuery(query);
        return finder.found
            || (finder.selectsMeasures && !lookupCubeMeasures(query).isEmpty());
    }

    /**
     * Returns the calculated measures that call LookupCube and that a query
     * can select with a function, such as {@code [Measures].AllMembers}.
     * Such measures are not among the measures that the query refers to.
     *
     * @param query Query
     * @return Calculated measures, or an empty list if the query selects no
     * measures with a function
     */
    public static List<Member> getSelectedLookupCubeMeasures(Query query) {
        return findInQuery(query).selectsMeasures
            ? lookupCubeMeasures(query)
            : Collections.<Member>emptyList();
    }

    private static LookupCubeFinder findInQuery(Query query) {
        final LookupCubeFinder finder = new LookupCubeFinder();
        for (Formula formula : query.getFormulas()) {
            finder.visitExp(formula.getExpression());
        }
        for (QueryAxis axis : query.getAxes()) {
            finder.visitExp(axis.getSet());
        }
        if (query.getSlicerAxis() != null) {
            finder.visitExp(query.getSlicerAxis().getSet());
        }
        return finder;
    }

    private static List<Member> lookupCubeMeasures(Query query) {
        final List<Member> measures = new ArrayList<Member>();
        for (Dimension dimension : query.getCube().getDimensions()) {
            if (!dimension.isMeasures()) {
                continue;
            }
            for (Member member : query.getSchemaReader(false)
                .getCalculatedMembers(dimension.getHierarchies()[0]))
            {
                if (containsLookupCube(member.getExpression())) {
                    measures.add(member);
                }
            }
        }
        return measures;
    }

    /**
     * Returns whether an expression calls LookupCube, directly or through
     * calculated members and named sets.
     *
     * @param exp Expression
     * @return Whether the expression uses LookupCube
     */
    public static boolean containsLookupCube(Exp exp) {
        final LookupCubeFinder finder = new LookupCubeFinder();
        finder.visitExp(exp);
        return finder.found;
    }

    private static class LookupCubeCalc extends GenericCalc {
        private final StringCalc cubeNameCalc;
        private final StringCalc expressionCalc;
        private final boolean mapAll;
        private final HierarchyCalc[] hierarchyCalcs;
        private final DimensionCalc[] dimensionCalcs;
        private final boolean mapsContext;

        LookupCubeCalc(
            ResolvedFunCall call,
            Calc[] calcs,
            StringCalc cubeNameCalc,
            StringCalc expressionCalc,
            boolean mapAll,
            List<HierarchyCalc> hierarchyCalcs,
            List<DimensionCalc> dimensionCalcs)
        {
            super(call, calcs);
            this.cubeNameCalc = cubeNameCalc;
            this.expressionCalc = expressionCalc;
            this.mapAll = mapAll;
            this.hierarchyCalcs =
                hierarchyCalcs.toArray(new HierarchyCalc[hierarchyCalcs.size()]);
            this.dimensionCalcs =
                dimensionCalcs.toArray(new DimensionCalc[dimensionCalcs.size()]);
            this.mapsContext =
                mapAll
                || !hierarchyCalcs.isEmpty()
                || !dimensionCalcs.isEmpty();
        }

        public Object evaluate(Evaluator evaluator) {
            final String cubeName = cubeNameCalc.evaluateString(evaluator);
            final String expression = expressionCalc.evaluateString(evaluator);
            if (cubeName == null || expression == null) {
                return null;
            }
            List<Hierarchy> hierarchies = null;
            if (hierarchyCalcs.length > 0) {
                hierarchies = new ArrayList<Hierarchy>(hierarchyCalcs.length);
                for (HierarchyCalc calc : hierarchyCalcs) {
                    hierarchies.add(calc.evaluateHierarchy(evaluator));
                }
            }
            List<Dimension> dimensions = null;
            if (dimensionCalcs.length > 0) {
                dimensions = new ArrayList<Dimension>(dimensionCalcs.length);
                for (DimensionCalc calc : dimensionCalcs) {
                    dimensions.add(calc.evaluateDimension(evaluator));
                }
            }
            if (!(evaluator instanceof RolapEvaluator)) {
                throw FunUtil.newEvalException(
                    null, "LookupCube requires a relational OLAP evaluator");
            }
            return ((RolapEvaluator) evaluator).evaluateInCube(
                cubeName, expression, mapAll, hierarchies, dimensions);
        }

        public boolean dependsOn(Hierarchy hierarchy) {
            // A mapped context makes the value depend on the current members
            // of the source cube. Without mapping, only the arguments do.
            return mapsContext || super.dependsOn(hierarchy);
        }
    }

    /**
     * Finds LookupCube calls in an expression and in the calculated members
     * that it refers to.
     */
    private static class LookupCubeFinder extends MdxVisitorImpl {
        private final Set<Object> visited = new HashSet<Object>();
        private boolean found;
        private boolean selectsMeasures;

        void visitExp(Exp exp) {
            if (!found && exp != null) {
                exp.accept(this);
            }
        }

        public Object visit(NamedSetExpr namedSetExpr) {
            final NamedSet namedSet = namedSetExpr.getNamedSet();
            if (visited.add(namedSet)) {
                visitExp(namedSet.getExp());
            }
            return null;
        }

        public Object visit(ResolvedFunCall call) {
            if (call.getFunDef() instanceof LookupCubeFunDef) {
                found = true;
                turnOffVisitChildren();
            } else if (isMeasuresSelection(call)) {
                selectsMeasures = true;
            }
            return null;
        }

        /**
         * Returns whether a call returns measures that its arguments do not
         * name, such as {@code [Measures].AllMembers}.
         * {@code [Measures].CurrentMember} returns the measure that the axes
         * select, so it does not select measures.
         */
        private static boolean isMeasuresSelection(ResolvedFunCall call) {
            if (!returnsMeasures(call.getType())
                || call.getFunName().equalsIgnoreCase("CurrentMember"))
            {
                return false;
            }
            for (Exp arg : call.getArgs()) {
                if (returnsMeasures(arg.getType())) {
                    return false;
                }
            }
            return true;
        }

        private static boolean returnsMeasures(Type type) {
            if (type instanceof SetType) {
                return returnsMeasures(((SetType) type).getElementType());
            }
            if (type instanceof TupleType) {
                for (Type elementType : ((TupleType) type).elementTypes) {
                    if (returnsMeasures(elementType)) {
                        return true;
                    }
                }
                return false;
            }
            if (!(type instanceof MemberType)) {
                return false;
            }
            final Dimension dimension = type.getDimension();
            return dimension != null && dimension.isMeasures();
        }

        public Object visit(MemberExpr memberExpr) {
            final Member member = memberExpr.getMember();
            if (member.isCalculated() && visited.add(member)) {
                visitExp(member.getExpression());
            }
            return null;
        }
    }

    private static class ResolverImpl extends ResolverBase {
        ResolverImpl() {
            super(
                "LookupCube",
                "LookupCube(<Cube Name>, <Expression String>"
                + "[, SHARED_CONTEXT | <Dimension or Hierarchy>[, ...]])",
                "Returns the value of an MDX expression evaluated in another "
                + "cube.",
                Syntax.Function);
        }

        public FunDef resolve(
            Exp[] args,
            Validator validator,
            List<Conversion> conversions)
        {
            if (args.length < 2) {
                return null;
            }
            final int[] categories = new int[args.length];
            for (int i = 0; i < 2; i++) {
                if (!validator.canConvert(
                        i, args[i], Category.String, conversions))
                {
                    return null;
                }
                categories[i] = Category.String;
            }
            for (int i = 2; i < args.length; i++) {
                final int category = args[i].getCategory() & Category.Mask;
                if (category == Category.Dimension
                    || category == Category.Hierarchy)
                {
                    categories[i] = category;
                } else if (args.length == 3 && isSharedContext(args[i])) {
                    categories[i] = Category.Symbol;
                } else {
                    return null;
                }
            }
            return new LookupCubeFunDef(
                new FunDefBase(this, Category.Value, categories) {
                });
        }

        public String[] getReservedWords() {
            return new String[] {SHARED_CONTEXT};
        }

        private static boolean isSharedContext(Exp arg) {
            return arg instanceof Literal
                && (arg.getCategory() & Category.Mask) == Category.Symbol
                && SHARED_CONTEXT.equals(((Literal) arg).getValue());
        }
    }
}

// End LookupCubeFunDef.java
