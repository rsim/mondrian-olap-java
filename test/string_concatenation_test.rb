# frozen_string_literal: true

require_relative "test_helper"

# BuiltinFunTable registers "+" also with two string arguments, as in the
# Microsoft MDX dialect, and shares its calc with "||". Both operators convert
# a member or a number operand to its string value and skip a null operand.
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

  it "should concatenate a string and a measure value with +" do
    assert_expression_returns @olap, %q("Sales: " + [Measures].[Unit Sales]), "Sales: 266773.0"
  end

  it "should concatenate a string and a measure value with ||" do
    assert_expression_returns @olap, %q("Sales: " || [Measures].[Unit Sales]), "Sales: 266773.0"
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
