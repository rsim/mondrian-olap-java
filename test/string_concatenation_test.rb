# frozen_string_literal: true

require_relative "test_helper"

# BuiltinFunTable registers "+" also with two string arguments, as in the
# Microsoft MDX dialect, and shares its calc with "||". Both operators convert
# a member or a number operand to its plain decimal string, which depends
# neither on the Java type and scale that the JDBC driver returns nor on the
# binary representation error of a double, and skip a null operand.
# Numeric does not convert to String, so a string with a number literal still
# matches no "+" overload.
describe "String concatenation" do
  before(:all) do
    create_olap_connection
  end

  after(:all) do
    @olap.close
  end

  it "should concatenate two strings with +" do
    assert_expression_returns @olap, %q("Unit" + " Sales"), "Unit Sales"
  end

  it "should concatenate three strings with +" do
    assert_expression_returns @olap, %q("Unit" + " " + "Sales"), "Unit Sales"
  end

  it "should concatenate a string and an integral measure value with +" do
    assert_expression_returns @olap, %q("Sales: " + [Measures].[Unit Sales]), "Sales: 266773"
  end

  it "should concatenate a string and a decimal measure value with +" do
    assert_expression_returns @olap, %q("Sales: " + [Measures].[Store Sales]), "Sales: 565238.13"
  end

  it "should round a double sum to its decimal digits" do
    mdx = <<~MDX
      WITH MEMBER [Measures].[_Sum] AS '0.1 + 0.2'
      MEMBER [Measures].[_Expr] AS '"Sum: " + [Measures].[_Sum]'
      SELECT {[Measures].[_Expr]} ON 0
      FROM [Sales]
    MDX
    assert_equal "Sum: 0.3", @olap.execute(mdx).formatted_values.flatten.first
  end

  it "should concatenate infinite and NaN measure values" do
    mdx = <<~MDX
      WITH MEMBER [Measures].[_Infinity] AS '1 / 0'
      MEMBER [Measures].[_NaN] AS '0 / 0'
      MEMBER [Measures].[_Infinity Expr] AS '"Ratio: " || [Measures].[_Infinity]'
      MEMBER [Measures].[_NaN Expr] AS '"Ratio: " + [Measures].[_NaN]'
      SELECT {[Measures].[_Infinity Expr], [Measures].[_NaN Expr]} ON 0
      FROM [Sales]
    MDX
    assert_equal ["Ratio: Infinity", "Ratio: NaN"], @olap.execute(mdx).formatted_values.flatten
  end

  it "should concatenate a string and a measure value with ||" do
    assert_expression_returns @olap, %q("Sales: " || [Measures].[Unit Sales]), "Sales: 266773"
  end

  it "should concatenate a string and a member name with +" do
    assert_expression_returns @olap, %q("Gender: " + [Gender].[F].Name), "Gender: F"
  end

  it "should skip an empty measure value" do
    assert_expression_returns @olap, %q("Sales: " + ([Measures].[Unit Sales], [Time].[1998])), "Sales: "
  end

  it "should add two numbers with +" do
    assert_expression_returns @olap, "1 + 2", "3"
  end

  it "should add two measures with +" do
    assert_expression_returns @olap, "[Measures].[Unit Sales] + [Measures].[Unit Sales]", "533,546"
  end

  it "should add two Value operands with +" do
    assert_expression_returns @olap, %q(CoalesceEmpty(1, "x") + CoalesceEmpty(2, "x")), "3"
  end

  it "should add a Value operand and NULL with +" do
    assert_expression_returns @olap, %q(CoalesceEmpty(1, "x") + NULL), "1"
  end

  it "should add NULL and NULL with +" do
    assert_expression_returns @olap, "NULL + NULL", ""
  end

  it "should concatenate a string and a Value operand with +" do
    assert_expression_returns @olap, %q("Value: " + CoalesceEmpty(1, "x")), "Value: 1"
  end

  it "should not add a string and a number with +" do
    mdx = <<~MDX
      WITH MEMBER [Measures].[_Expr] AS '"Sales: " + 1'
      SELECT {[Measures].[_Expr]} ON 0
      FROM [Sales]
    MDX
    error = assert_raises(Mondrian::OLAP::Error) { @olap.execute(mdx) }
    assert_match "No function matches signature '<String> + <Numeric Expression>'", error.root_cause_message
  end
end
