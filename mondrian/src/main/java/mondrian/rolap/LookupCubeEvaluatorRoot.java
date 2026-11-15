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

import mondrian.olap.Evaluator;
import mondrian.olap.Exp;
import mondrian.olap.NamedSet;
import mondrian.olap.Query;
import mondrian.server.Statement;

/**
 * Evaluator root for the target cube of the LookupCube function.
 *
 * <p>The root belongs to the execution of the source query: it shares its
 * {@link mondrian.server.Execution}, so cancellation and timeouts apply, and
 * it evaluates sets through the source {@link RolapResult}, so that set
 * evaluation runs the same cell loading phases as the source query.
 */
class LookupCubeEvaluatorRoot extends RolapResult.RolapResultEvaluatorRoot {
    private final RolapEvaluatorRoot owner;
    private RolapEvaluator slicerEvaluator;

    /**
     * Creates a LookupCubeEvaluatorRoot.
     *
     * @param owner Root of the source query that owns lookup contexts
     * @param result Source query result, or null if the source evaluation
     * does not belong to a query result
     * @param statement Statement of the target cube query
     * @param query Target cube query
     */
    LookupCubeEvaluatorRoot(
        RolapEvaluatorRoot owner,
        RolapResult result,
        Statement statement,
        Query query)
    {
        super(result, statement, query, owner.execution);
        this.owner = owner;
    }

    /**
     * Sets the evaluator with the default context of the target cube. Sets
     * are evaluated in this context, as named sets are evaluated in the
     * slicer context of a query.
     */
    void setSlicerEvaluator(RolapEvaluator slicerEvaluator) {
        this.slicerEvaluator = slicerEvaluator;
    }

    @Override
    RolapEvaluatorRoot getLookupCubeOwner() {
        return owner;
    }

    @Override
    protected RolapEvaluator getSlicerEvaluator() {
        return slicerEvaluator;
    }

    @Override
    protected Evaluator.NamedSetEvaluator evaluateNamedSet(
        NamedSet namedSet,
        boolean create)
    {
        checkResult();
        return super.evaluateNamedSet(namedSet, create);
    }

    @Override
    protected Evaluator.SetEvaluator evaluateSet(Exp exp, boolean create) {
        checkResult();
        return super.evaluateSet(exp, create);
    }

    private void checkResult() {
        if (result == null) {
            throw LookupCubeContext.error(
                "LookupCube cannot evaluate sets of cube '"
                + cube.getName() + "' outside of a query");
        }
    }
}

// End LookupCubeEvaluatorRoot.java
