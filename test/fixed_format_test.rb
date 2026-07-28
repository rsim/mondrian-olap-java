# frozen_string_literal: true

require_relative "test_helper"

# Functions whose result type is fixed (independent of their arguments) should
# use a fixed default format string rather than inheriting the format of the
# first member found in the expression.
describe "Fixed default formatting for fixed-output functions" do
  before(:all) do
    create_olap_connection
    # Pin the connection locale so the 'mmm dd yyyy' month abbreviations stay
    # in English regardless of the machine's default locale.
    @olap.locale = 'en'
  end

  describe "Count defaults to an integer format" do
    it "uses a fixed integer format instead of inheriting a member format" do
      result = @olap.from('Sales').
        with_member('[Measures].[Custom]').as(
          '[Measures].[Unit Sales]', format_string: '$#,##0.0000'
        ).
        with_member('[Measures].[Cnt]').as(
          "Count(Filter([Customers].[USA].Children, [Measures].[Custom] > 0))"
        ).
        columns('[Measures].[Cnt]').execute
      # Must not leak the '$#,##0.0000' format from the Filter predicate.
      assert_equal '3', result.formatted_values[0]
    end
  end

  describe "DateAdd defaults to a date format" do
    it "formats the result as 'mmm dd yyyy'" do
      result = @olap.from('Sales').
        with_member('[Measures].[D]').as("DateAdd('d', 7, DateSerial(2020, 12, 15))").
        columns('[Measures].[D]').execute
      assert_equal 'Dec 22 2020', result.formatted_values[0]
    end
  end

  describe "DateSerial defaults to a date format" do
    it "formats the result as 'mmm dd yyyy'" do
      result = @olap.from('Sales').
        with_member('[Measures].[D]').as("DateSerial(2020, 12, 15)").
        columns('[Measures].[D]').execute
      assert_equal 'Dec 15 2020', result.formatted_values[0]
    end
  end

  describe "the fixed format applies only to default formatting" do
    it "keeps an explicit format string over the fixed date format" do
      result = @olap.from('Sales').
        with_member('[Measures].[D]').as(
          "DateSerial(2020, 12, 15)", format_string: 'dd.mm.yyyy'
        ).
        columns('[Measures].[D]').execute
      assert_equal '15.12.2020', result.formatted_values[0]
    end

    it "does not apply the fixed format when nested inside another function" do
      result = @olap.from('Sales').
        with_member('[Measures].[Custom]').as(
          '[Measures].[Unit Sales]', format_string: '$#,##0.0000'
        ).
        with_member('[Measures].[R]').as(
          "[Measures].[Custom] + Count([Customers].[USA].Children)"
        ).
        columns('[Measures].[R]').execute
      # Top-level expression is '+', not Count; format inference walks to
      # [Custom], so Count's fixed integer format must not take over.
      assert_match(/\A\$/, result.formatted_values[0])
    end
  end
end
