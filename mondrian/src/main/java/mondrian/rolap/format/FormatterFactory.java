/*
// This software is subject to the terms of the Eclipse Public License v1.0
// Agreement, available at the following URL:
// http://www.eclipse.org/legal/epl-v10.html.
// You must accept the terms of that agreement to use this software.
//
// Copyright (C) 2016-2017 Hitachi Vantara and others
// All Rights Reserved.
*/
package mondrian.rolap.format;

import mondrian.olap.MondrianProperties;
import mondrian.resource.MondrianResource;
import mondrian.spi.CellFormatter;
import mondrian.spi.MemberFormatter;
import mondrian.spi.PropertyFormatter;
import mondrian.spi.impl.Scripts;

import java.lang.reflect.Constructor;

/**
 * Formatter factory to provide a single point
 * to create different formatters for element values.
 *
 * <p/>
 * Uses provided context data to instantiate a formatter for the element
 * either by specified class name or script.
 */
public class FormatterFactory {

    /**
     * The default formatter which is used
     * when no custom formatter is specified.
     */
    private static final DefaultFormatter DEFAULT_FORMATTER =
        new DefaultFormatter();


    private static final PropertyFormatter DEFAULT_PROPERTY_FORMATTER =
        new PropertyFormatterAdapter(DEFAULT_FORMATTER);

    private static final MemberFormatter DEFAULT_MEMBER_FORMATTER =
        new DefaultRolapMemberFormatter(DEFAULT_FORMATTER);


    private static final FormatterFactory INSTANCE = new FormatterFactory();

    private FormatterFactory() {
    }

    public static FormatterFactory instance() {
        return INSTANCE;
    }

    /**
     * Given the name of a cell formatter class and/or a cell formatter script,
     * returns a cell formatter.
     * <p>
     *     Returns null if empty context is passed.
     * </p>
     */
    public CellFormatter createCellFormatter(FormatterCreateContext context) {
        // PATCH: Cell formatters can be specified in MDX queries, so check
        // them against the configured restrictions before any class is
        // loaded or any script is compiled.
        checkCellFormatterAllowed(context);
        try {
            if (context.getFormatterClassName() != null) {
                return createFormatter(
                    context.getFormatterClassName(), CellFormatter.class);
            }
            if (context.getScriptText() != null) {
                return Scripts.cellFormatter(
                    context.getScriptText(),
                    context.getScriptLanguage());
            }
        } catch (Exception e) {
            throw MondrianResource.instance().CellFormatterLoadFailed.ex(
                context.getFormatterClassName(),
                context.getElementName(),
                e);
        }
        return null;
    }

    /**
     * Given the name of a member formatter class
     * and/or a member formatter script, returns a member formatter.
     * <p>
     *     Returns default formatter implementation
     *     if empty context is passed.
     * </p>
     */
    public MemberFormatter createRolapMemberFormatter(
        FormatterCreateContext context)
    {
        try {
            if (context.getFormatterClassName() != null) {
                return createFormatter(
                    context.getFormatterClassName(), MemberFormatter.class);
            }
            if (context.getScriptText() != null) {
                return Scripts.memberFormatter(
                    context.getScriptText(),
                    context.getScriptLanguage());
            }
        } catch (Exception e) {
            throw MondrianResource.instance().MemberFormatterLoadFailed.ex(
                context.getFormatterClassName(),
                context.getElementName(),
                e);
        }
        return DEFAULT_MEMBER_FORMATTER;
    }

    /**
     * Given the name of a property formatter class
     * and/or a property formatter script,
     * returns a property formatter.
     * <p>
     *     Returns default formatter implementation
     *     if empty context is passed.
     * </p>
     */
    public PropertyFormatter createPropertyFormatter(
        FormatterCreateContext context)
    {
        try {
            if (context.getFormatterClassName() != null) {
                return createFormatter(
                    context.getFormatterClassName(), PropertyFormatter.class);
            }
            if (context.getScriptText() != null) {
                return Scripts.propertyFormatter(
                    context.getScriptText(),
                    context.getScriptLanguage());
            }
        } catch (Exception e) {
            throw MondrianResource.instance().PropertyFormatterLoadFailed.ex(
                context.getFormatterClassName(),
                context.getElementName(),
                e);
        }
        return DEFAULT_PROPERTY_FORMATTER;
    }

    // PATCH: Mirrors the precedence of createCellFormatter, where the class
    // name is used when present and the script is used otherwise.
    private static void checkCellFormatterAllowed(
        FormatterCreateContext context)
    {
        final MondrianProperties properties = MondrianProperties.instance();
        final String className = context.getFormatterClassName();
        if (className != null) {
            if (!isClassNameAllowed(
                    className, properties.CellFormatterAllowedClasses.get()))
            {
                throw MondrianResource.instance().CellFormatterClassNotAllowed
                    .ex(className, context.getElementName());
            }
        } else if (context.getScriptText() != null
            && !properties.CellFormatterScriptEnabled.get())
        {
            throw MondrianResource.instance().CellFormatterScriptDisabled
                .ex(context.getElementName());
        }
    }

    // PATCH: An empty list allows any class name. An entry ending with "*"
    // matches by prefix, as dynamically generated classes (for example,
    // JRuby formatters) share a package prefix but have varying names.
    private static boolean isClassNameAllowed(
        String className,
        String allowedList)
    {
        if (allowedList == null || allowedList.trim().isEmpty()) {
            return true;
        }
        for (String entry : allowedList.split(",")) {
            final String allowed = entry.trim();
            if (allowed.isEmpty()) {
                continue;
            }
            if (allowed.endsWith("*")) {
                final String prefix =
                    allowed.substring(0, allowed.length() - 1);
                if (className.startsWith(prefix)) {
                    return true;
                }
            } else if (className.equals(allowed)) {
                return true;
            }
        }
        return false;
    }

    // PATCH: Load the class without initializing it and check that it
    // implements the formatter interface before it is instantiated, so that
    // a formatter class name (which can come from an MDX query) cannot run
    // the static initializer or the constructor of an arbitrary class.
    private static <T> T createFormatter(
        String className,
        Class<T> formatterInterface) throws Exception
    {
        final Class<?> clazz = Class.forName(
            className, false, FormatterFactory.class.getClassLoader());
        // Class#asSubclass would throw a ClassCastException that names only
        // the loaded class, so name the expected interface too.
        if (!formatterInterface.isAssignableFrom(clazz)) {
            throw new ClassCastException(
                clazz + " does not implement " + formatterInterface);
        }
        final Constructor<? extends T> constructor =
            clazz.asSubclass(formatterInterface).getConstructor();
        return constructor.newInstance();
    }
}
// End FormatterFactory.java