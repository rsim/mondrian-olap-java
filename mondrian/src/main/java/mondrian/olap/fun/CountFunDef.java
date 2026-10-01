/*
* This software is subject to the terms of the Eclipse Public License v1.0
* Agreement, available at the following URL:
* http://www.eclipse.org/legal/epl-v10.html.
* You must accept the terms of that agreement to use this software.
*
* Copyright (c) 2002-2021 Hitachi Vantara..  All rights reserved.
*/

package mondrian.olap.fun;

import mondrian.calc.*;
import mondrian.calc.impl.AbstractIntegerCalc;
import mondrian.mdx.ResolvedFunCall;
import mondrian.olap.*;

/**
 * Definition of the <code>Count</code> MDX function.
 *
 * @author jhyde
 * @since Mar 23, 2006
 */
class CountFunDef extends AbstractAggregateFunDef
    implements FormatAwareFunDef
{
  static final String[] ReservedWords = new String[] { "INCLUDEEMPTY", "EXCLUDEEMPTY" };

  static final ReflectiveMultiResolver Resolver =
      new ReflectiveMultiResolver( "Count", "Count(<Set>[, EXCLUDEEMPTY | INCLUDEEMPTY])",
          "Returns the number of tuples in a set, empty cells included unless the optional EXCLUDEEMPTY flag is used.",
          new String[] { "fnx", "fnxy" }, CountFunDef.class, ReservedWords );
  private static final String TIMING_NAME = CountFunDef.class.getSimpleName();

  public CountFunDef( FunDef dummyFunDef ) {
    super( dummyFunDef );
  }

  // PATCH: Count always returns an integer, so a calculated member using it as
  // its formula should default to an integer format rather than inheriting the
  // format of a measure found in the counted set.
  public String getFixedFormatString() {
    return INTEGER_FORMAT_STRING;
  }

  public Calc compileCall( ResolvedFunCall call, ExpCompiler compiler ) {
    final Calc calc = compiler.compileAs( call.getArg( 0 ), null, ResultStyle.ITERABLE_ANY );
    final boolean includeEmpty =
        call.getArgCount() < 2 || ( (Literal) call.getArg( 1 ) ).getValue().equals( "INCLUDEEMPTY" );
    return new AbstractIntegerCalc( call, new Calc[] { calc } ) {
      public int evaluateInteger( Evaluator evaluator ) {
        evaluator.getTiming().markStart( TIMING_NAME );
        final int savepoint = evaluator.savepoint();
        try {
          evaluator.setNonEmpty( false );
          final int count;
          if ( calc instanceof IterCalc ) {
            IterCalc iterCalc = (IterCalc) calc;
            TupleIterable iterable = evaluateCurrentIterable( iterCalc, evaluator );
            count = count( evaluator, iterable, includeEmpty );
          } else {
            // must be ListCalc
            ListCalc listCalc = (ListCalc) calc;
            TupleList list = evaluateCurrentList( listCalc, evaluator );
            count = count( evaluator, list, includeEmpty );
          }
          return count;
        } finally {
          evaluator.restore( savepoint );
          evaluator.getTiming().markEnd( TIMING_NAME );
        }
      }

      public boolean dependsOn( Hierarchy hierarchy ) {
        // COUNT(<set>, INCLUDEEMPTY) is straightforward -- it
        // depends only on the dimensions that <Set> depends
        // on.
        if ( super.dependsOn( hierarchy ) ) {
          return true;
        }
        if ( includeEmpty ) {
          return false;
        }
        // COUNT(<set>, EXCLUDEEMPTY) depends only on the
        // dimensions that <Set> depends on, plus all
        // dimensions not masked by the set.
        return !calc.getType().usesHierarchy( hierarchy, true );
      }
    };
  }

  /**
   * Definition of the <code>&lt;Set&gt;.Count</code> property form, which
   * counts tuples with empty cells included.
   *
   * <p>PATCH: moved here from {@link BuiltinFunTable}, where it was an
   * anonymous class and so could not implement {@link FormatAwareFunDef}.
   * Keeping both Count definitions in one file stops their format strings
   * from drifting apart.
   */
  static class SetPropertyFunDef extends FunDefBase
      implements FormatAwareFunDef
  {
    SetPropertyFunDef() {
      super( "Count", "Returns the number of tuples in a set including empty cells.", "pnx" );
    }

    public String getFixedFormatString() {
      return INTEGER_FORMAT_STRING;
    }

    public Calc compileCall( ResolvedFunCall call, ExpCompiler compiler ) {
      final ListCalc listCalc = compiler.compileList( call.getArg( 0 ) );
      return new AbstractIntegerCalc( call, new Calc[] { listCalc } ) {
        public int evaluateInteger( Evaluator evaluator ) {
          TupleList list = listCalc.evaluateList( evaluator );
          return count( evaluator, list, true );
        }
      };
    }
  }
}

// End CountFunDef.java
