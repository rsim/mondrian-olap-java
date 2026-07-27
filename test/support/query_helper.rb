# frozen_string_literal: true

module QueryHelper
  # Format a result using the same formatter Java tests use.
  def format_result(result)
    string_writer = Java::JavaIo::StringWriter.new
    print_writer = Java::JavaIo::PrintWriter.new(string_writer)
    Java::OrgOlap4jLayout::TraditionalCellSetFormatter.new.format(result.raw_cell_set, print_writer)
    print_writer.flush
    string_writer.toString
  end

  # Execute MDX and assert the formatted result matches expected.
  # Uses assert_like (whitespace-normalized comparison from test_helper.rb).
  def assert_query_returns(olap, mdx, expected)
    result = olap.execute(mdx)
    actual = format_result(result)
    assert_like expected, actual
  end

  # Execute an axis expression against a cube (default: Sales).
  # Asserts member full names match expected (one per line).
  # Formats each position as "{member1, member2}" for tuples,
  # or just "member" for single-member positions.
  def assert_axis_returns(olap, expression, expected, cube: "Sales")
    mdx = "SELECT {#{expression}} ON 0 FROM [#{cube}]"
    cell_set = olap.execute(mdx).raw_cell_set
    axis = cell_set.getAxes.get(0)
    lines = axis.getPositions.map do |position|
      members = position.getMembers
      if members.size == 1
        members.get(0).getUniqueName
      else
        names = members.map { |m| m.getUniqueName }
        "{#{names.join(', ')}}"
      end
    end
    assert_equal expected.strip, lines.join("\n").strip
  end

  # Evaluate a scalar expression against a cube.
  # Wraps it in WITH MEMBER + SELECT, asserts the formatted cell value.
  def assert_expression_returns(olap, expression, expected, cube: "Sales")
    mdx = <<~MDX
      WITH MEMBER [Measures].[_Expr] AS '#{expression}'
      SELECT {[Measures].[_Expr]} ON 0
      FROM [#{cube}]
    MDX
    actual = olap.execute(mdx).formatted_values.flatten.first
    assert_equal expected.strip, actual.to_s.strip
  end

  # Assert that executing MDX raises a Mondrian error matching the pattern.
  # Pattern can be a Regexp or a String (substring match); assert_match handles both.
  def assert_query_raises(olap, mdx, pattern)
    error = assert_raises(Mondrian::OLAP::Error) { olap.execute(mdx) }
    assert_match pattern, error.message
  end

  # The list of hierarchies in the FoodMart Sales cube, in cube definition
  # order. Mirrors TestContext.AllHiers in the Java test suite; the weekly
  # hierarchy name depends on the SsasCompatibleNaming property.
  def all_hiers
    weekly =
      Java::MondrianOlap::MondrianProperties.instance.SsasCompatibleNaming.get ? "[Time].[Weekly]" : "[Time.Weekly]"
    [
      "[Measures]", "[Store]", "[Store Size in SQFT]", "[Store Type]", "[Time]", weekly,
      "[Product]", "[Promotion Media]", "[Promotions]", "[Customers]",
      "[Education Level]", "[Gender]", "[Marital Status]", "[Yearly Income]"
    ]
  end

  # Builds the "{...}" string of all Sales-cube hierarchies except those given.
  # Useful as the expected argument to assert_expr_depends_on. Mirrors
  # TestContext.allHiersExcept.
  def all_hiers_except(*hiers)
    hiers.each do |hier|
      raise ArgumentError, "unknown hierarchy #{hier}" unless all_hiers.include?(hier)
    end
    "{#{all_hiers.reject { |hier| hiers.include?(hier) }.join(', ')}}"
  end

  # Assert that a scalar MDX expression depends upon a given set of hierarchies.
  # Mirrors TestContext#assertExprDependsOn: the expression is compiled inside a
  # calculated member and each cube hierarchy is checked via Calc#dependsOn.
  def assert_expr_depends_on(olap, expr, hier_list)
    query_string =
      "WITH MEMBER [Measures].[Foo] AS #{Java::MondrianOlap::Util.singleQuoteString(expr)} SELECT FROM [Sales]"
    query = olap.raw_mondrian_connection.parseQuery(query_string)
    query.resolve
    expression = query.getFormulas[0].getExpression
    _assert_depends_on(query, expression, hier_list, true)
  end

  # Assert that a set-valued MDX expression depends upon a given set of dimensions.
  # Mirrors TestContext#assertSetExprDependsOn.
  def assert_set_expr_depends_on(olap, expr, dim_list)
    query_string = "SELECT {#{expr}} ON COLUMNS FROM [Sales]"
    query = olap.raw_mondrian_connection.parseQuery(query_string)
    query.resolve
    expression = query.getAxes[0].getSet
    _assert_depends_on(query, expression, dim_list, false)
  end

  # Assert that a member-valued MDX expression depends upon a given set of dimensions.
  # Mirrors TestContext#assertMemberExprDependsOn.
  def assert_member_expr_depends_on(olap, expr, dim_list)
    assert_set_expr_depends_on(olap, "{#{expr}}", dim_list)
  end

  # Compiles the expression, then builds the "{...}" list of cube hierarchies it
  # depends on (in cube order) and asserts it equals the expected list.
  def _assert_depends_on(query, expression, expected, scalar)
    result_style = scalar ? nil : Java::MondrianCalc::ResultStyle::ITERABLE
    calc = query.compileExpression(expression, scalar, result_style)
    depends = query.getCube.getHierarchies.to_a.select { |hierarchy| calc.dependsOn(hierarchy) }.map(&:getUniqueName)
    assert_equal expected, "{#{depends.join(', ')}}"
  end
end
