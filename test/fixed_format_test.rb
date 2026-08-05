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
    # MDX Count has two independent implementations - the function form
    # Count(<Set>) and the property form <Set>.Count - which must agree.
    {
      "Count(Filter([Customers].[USA].Children, [Measures].[Custom] > 0))" => 'function form',
      "Filter([Customers].[USA].Children, [Measures].[Custom] > 0).Count" => 'property form',
      "Count(Filter([Customers].[USA].Children, [Measures].[Custom] > 0), INCLUDEEMPTY)" => 'INCLUDEEMPTY form',
      "Count(Filter([Customers].[USA].Children, [Measures].[Custom] > 0), EXCLUDEEMPTY)" => 'EXCLUDEEMPTY form'
    }.each do |expression, form|
      it "does not inherit a member format from the counted set in the #{form}" do
        result = @olap.from('Sales').
          with_member('[Measures].[Custom]').as(
            '[Measures].[Unit Sales]', format_string: '$#,##0.0000'
          ).
          with_member('[Measures].[Cnt]').as(expression).
          columns('[Measures].[Cnt]').execute
        # Must not leak the '$#,##0.0000' format from the Filter predicate.
        assert_equal '3', result.formatted_values[0]
      end
    end

    it "formats both Count syntaxes identically" do
      result = @olap.from('Sales').
        with_member('[Measures].[Custom]').as(
          '[Measures].[Unit Sales]', format_string: '$#,##0.0000'
        ).
        with_member('[Measures].[Function]').as(
          "Count(Filter([Customers].[USA].Children, [Measures].[Custom] > 0))"
        ).
        with_member('[Measures].[Property]').as(
          "Filter([Customers].[USA].Children, [Measures].[Custom] > 0).Count"
        ).
        columns('[Measures].[Function]', '[Measures].[Property]').execute
      assert_equal result.formatted_values[0], result.formatted_values[1]
    end

    it "keeps an explicit format string over the fixed integer format" do
      result = @olap.from('Sales').
        with_member('[Measures].[Cnt]').as(
          "Count([Customers].[USA].Children)", format_string: '000'
        ).
        columns('[Measures].[Cnt]').execute
      assert_equal '003', result.formatted_values[0]
    end

    it "keeps an explicit format string over the fixed integer format in the property form" do
      result = @olap.from('Sales').
        with_member('[Measures].[Cnt]').as(
          "[Customers].[USA].Children.Count", format_string: '000'
        ).
        columns('[Measures].[Cnt]').execute
      assert_equal '003', result.formatted_values[0]
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

  describe "the other Vba functions with a fixed date or time result" do
    # Functions taking a fixed argument, so that the expected value is known.
    {
      "CDate(DateSerial(2020, 12, 15))" => 'Dec 15 2020',
      "DateValue(DateSerial(2020, 12, 15))" => 'Dec 15 2020',
      "TimeSerial(14, 30, 5)" => '14:30:05',
      "TimeValue(TimeSerial(14, 30, 5))" => '14:30:05'
    }.each do |expression, expected|
      it "formats #{expression} as '#{expected}'" do
        result = @olap.from('Sales').
          with_member('[Measures].[D]').as(expression).
          columns('[Measures].[D]').execute
        assert_equal expected, result.formatted_values[0]
      end
    end

    # Functions returning the current date or time, so only the shape of the
    # formatted value can be asserted.
    {
      "Date()" => /\A[A-Z][a-z]{2} \d{2} \d{4}\z/,
      "Now()" => /\A[A-Z][a-z]{2} \d{2} \d{4} \d{2}:\d{2}:\d{2}\z/,
      "Time()" => /\A\d{2}:\d{2}:\d{2}\z/
    }.each do |expression, expected|
      it "formats #{expression} as #{expected.source}" do
        result = @olap.from('Sales').
          with_member('[Measures].[D]').as(expression).
          columns('[Measures].[D]').execute
        assert_match expected, result.formatted_values[0]
      end
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
      assert_equal '$266,776.0000', result.formatted_values[0]
    end
  end

  # A fixed format becomes the member's format expression, so members without
  # an explicit format that reference the member inherit it through the same
  # walk that has always propagated user-set formats outward.
  describe "the fixed format propagates to referencing members" do
    it "renders a ratio of a Count member with the propagated integer format" do
      result = @olap.from('Sales').
        with_member('[Measures].[Cnt]').as(
          "Count([Customers].[USA].Children)"
        ).
        with_member('[Measures].[Share]').as(
          "[Measures].[Cnt] / 4"
        ).
        columns('[Measures].[Share]').execute
      # [Cnt] is 3; the walk from [Share] finds its fixed '#,##0', so the
      # ratio displays rounded to '1'. Display-only - the value keeps its
      # precision for anything that computes with it.
      assert_equal 0.75, result.values[0]
      assert_equal '1', result.formatted_values[0]
    end
  end
end
