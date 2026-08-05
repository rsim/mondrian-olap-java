/*
// This software is subject to the terms of the Eclipse Public License v1.0
// Agreement, available at the following URL:
// http://www.eclipse.org/legal/epl-v10.html.
// You must accept the terms of that agreement to use this software.
//
// Copyright (C) 2026 eazyBI
// All Rights Reserved.
*/

package mondrian.olap;

/**
 * Interface for functions that want to control which format string is
 * inferred for calculated members using this function.
 *
 * <p>When a calculated member has no explicit FORMAT_STRING and its
 * defining expression is a call to a function implementing this interface,
 * {@link Formula} consults the function instead of doing a depth-first walk
 * that picks the first measure it encounters. Two strategies are offered:
 *
 * <ul>
 * <li><b>Fixed format</b> — for functions whose result type is fixed and
 *     independent of their arguments (e.g. DateAdd always returns a date,
 *     Count always returns an integer). Implement
 *     {@link #getFixedFormatString()} to return a literal format string.</li>
 * <li><b>Argument-derived format</b> — for functions whose result type
 *     depends on the data (e.g. Min/Max return a date or a number depending
 *     on the value expression). Implement {@link #getFormatExpIndex(Exp[])}
 *     to name the argument whose format should be inherited.</li>
 * </ul>
 *
 * <p>A non-null {@link #getFixedFormatString()} takes precedence over
 * {@link #getFormatExpIndex(Exp[])}; a function normally implements only one.
 *
 * <p>Can be implemented by {@link FunDef} implementations directly
 * (e.g., Min/Max), or by {@link mondrian.spi.UserDefinedFunction}
 * implementations — the UDF adapter in UdfResolver delegates automatically.
 *
 * @since Mar 2026
 */
public interface FormatAwareFunDef {
    /**
     * Sentinel value indicating the function does not participate in
     * format-aware resolution (e.g., a UDF wrapper where the actual UDF
     * does not implement this interface). Formula will fall through to
     * the default format-finding behavior.
     */
    int NOT_PARTICIPATING = Integer.MIN_VALUE;

    /**
     * Format string for a function returning a whole number. Same string that
     * Mondrian's {@code "Standard"} format macro expands to, so a member using
     * it renders as it would with no format string at all.
     */
    String INTEGER_FORMAT_STRING = "#,##0";

    /**
     * Format string for a function returning a fractional number.
     */
    String DECIMAL_FORMAT_STRING = "#,##0.00";

    /**
     * Format string for a function returning a date with no meaningful time
     * of day. This is a {@link mondrian.util.Format} (VBA-style) pattern, not
     * a {@code SimpleDateFormat} one — {@code mm} means month here, and
     * minutes only directly after an hour token.
     */
    String DATE_FORMAT_STRING = "mmm dd yyyy";

    /**
     * Format string for a function returning a time of day.
     */
    String TIME_FORMAT_STRING = "hh:mm:ss";

    /**
     * Format string for a function returning a date with a meaningful time
     * of day.
     */
    String DATE_TIME_FORMAT_STRING = DATE_FORMAT_STRING + " " + TIME_FORMAT_STRING;

    /**
     * Returns a fixed format string to apply to the result of this function
     * call, regardless of its arguments, or {@code null} to fall back to
     * {@link #getFormatExpIndex(Exp[])}.
     *
     * <p>Use this for functions with a fixed result type — e.g. a date
     * function returning {@code "mmm dd yyyy"} or a counting function
     * returning {@code "#,##0"}. A non-null value takes precedence over
     * {@link #getFormatExpIndex(Exp[])}.
     *
     * @return a literal format string, or {@code null} if not applicable
     */
    default String getFixedFormatString() {
        return null;
    }

    /**
     * Returns the index of the argument whose format string should be
     * used for the result of this function call.
     *
     * <p>Return values:
     * <ul>
     * <li>{@code 0 <= index < args.length}: use the format from the
     *     argument at this index</li>
     * <li>{@code -1}: skip format inference from arguments entirely
     *     (useful when the function's result type differs from all
     *     argument types, e.g., DateDiffDays returns a number from
     *     two date arguments)</li>
     * <li>{@link #NOT_PARTICIPATING}: this function does not participate;
     *     fall through to the default format-finding behavior</li>
     * </ul>
     *
     * <p>Implementations must return one of the values above; other
     * values are treated as {@link #NOT_PARTICIPATING} (an assertion
     * in {@link Formula} fires only when assertions are enabled).
     *
     * @param args the arguments to the function call
     * @return argument index, -1 to skip, or NOT_PARTICIPATING
     */
    default int getFormatExpIndex(Exp[] args) {
        return NOT_PARTICIPATING;
    }
}
