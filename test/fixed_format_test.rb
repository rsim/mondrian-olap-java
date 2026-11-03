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

  # Every case gets the same support members, so a function that leaks the
  # format of an argument is visible. [Custom] carries a currency format,
  # [Explicit Date] a date format that the user chose, and [Fixed Date] the
  # fixed date format of DateSerial. The expression under test becomes [R].
  def formatted(expression, format_string: nil)
    options = format_string ? {format_string: format_string} : {}
    @olap.from('Sales').
      with_member('[Measures].[Custom]').as(
        '[Measures].[Unit Sales]', format_string: '$#,##0.0000'
      ).
      with_member('[Measures].[Explicit Date]').as(
        "DateSerial(2020, 12, 15)", format_string: 'dd.mm.yyyy'
      ).
      with_member('[Measures].[Fixed Date]').as("DateSerial(2020, 12, 15)").
      with_member('[Measures].[R]').as(expression, options).
      columns('[Measures].[R]').execute.formatted_values[0]
  end

  # A member without a format of its own takes the format of the member that it
  # references, through the same walk that propagates a user-set format.
  def referencing_result(referenced, referencing)
    @olap.from('Sales').
      with_member('[Measures].[Source]').as(referenced).
      with_member('[Measures].[R]').as(referencing).
      columns('[Measures].[R]').execute
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
        # Must not leak the '$#,##0.0000' format from the Filter predicate.
        assert_equal '3', formatted(expression)
      end
    end

    it "keeps an explicit format string over the fixed integer format" do
      assert_equal '003',
        formatted("Count([Customers].[USA].Children)", format_string: '000')
    end

    it "keeps an explicit format string over the fixed integer format in the property form" do
      assert_equal '003',
        formatted("[Customers].[USA].Children.Count", format_string: '000')
    end
  end

  # DateAdd can add an hour, minute or second interval, and it keeps the time
  # of day of its date argument, so a date-only format would hide the part
  # that the call just changed.
  describe "DateAdd defaults to a date and time format" do
    {
      "DateAdd('d', 7, DateSerial(2020, 12, 15))" => 'Dec 22 2020 00:00:00',
      "DateAdd('h', 5, DateSerial(2020, 12, 15))" => 'Dec 15 2020 05:00:00'
    }.each do |expression, expected|
      it "formats #{expression} as '#{expected}'" do
        assert_equal expected, formatted(expression)
      end
    end
  end

  # DateDiff counts whole intervals between two dates, so it returns a number.
  # The format of its date arguments must not become the format of that number.
  describe "DateDiff defaults to an integer format" do
    # DateDiff has three overloads and each one carries its own annotation, so
    # each one needs a case. The 'd' interval ignores the first day of the week
    # and the first week of the year, and the values below repeat the defaults
    # of the three-argument form, so all three forms count the same days.
    {
      'three arguments' => '',
      'four arguments' => ', 1',
      'five arguments' => ', 1, 1'
    }.each do |form, extra_arguments|
      # The date argument carries the fixed date format in the first case and
      # an explicit format in the second. Neither must reach the count.
      {
        'the fixed' => '[Measures].[Fixed Date]',
        'an explicit' => '[Measures].[Explicit Date]'
      }.each do |source, member|
        it "does not inherit #{source} date format of a date member with #{form}" do
          expression = "DateDiff('d', DateSerial(2020, 12, 1), #{member}#{extra_arguments})"
          assert_equal '14', formatted(expression)
        end
      end
    end

    # Every other case in this file renders a value below one thousand, so the
    # group separator of the integer constant stays unproven. A span of eleven
    # years passes one thousand days.
    it "renders the group separator of the integer format" do
      assert_equal '4,032',
        formatted("DateDiff('d', DateSerial(2009, 12, 1), [Measures].[Explicit Date])")
    end
  end

  describe "DateSerial defaults to a date format" do
    it "formats the result as 'mmm dd yyyy'" do
      assert_equal 'Dec 15 2020', formatted("DateSerial(2020, 12, 15)")
    end
  end

  # CDate keeps the time of day of its argument, so unlike DateValue its fixed
  # format holds a time component.
  #
  # The three string cases below fail with a default locale that has a
  # non-Gregorian calendar, such as th_TH. Only three of the 748
  # available locales have another calendar, so this was deemed acceptable.
  describe "CDate defaults to a date and time format" do
    {
      "CDate(DateSerial(2020, 12, 15))" => 'Dec 15 2020 00:00:00',
      "CDate(DateAdd('h', 5, DateSerial(2020, 12, 15)))" => 'Dec 15 2020 05:00:00',
      "CDate('2020-12-15')" => 'Dec 15 2020 00:00:00',
      "CDate('2020-12-15 16:35:47')" => 'Dec 15 2020 16:35:47',
      # A time without a date gets the epoch date.
      "CDate('16:35:47')" => 'Jan 01 1970 16:35:47'
    }.each do |expression, expected|
      it "formats #{expression} as '#{expected}'" do
        assert_equal expected, formatted(expression)
      end
    end
  end

  describe "the other Vba functions with a fixed date or time result" do
    # Functions taking a fixed argument, so that the expected value is known.
    {
      "DateValue(DateSerial(2020, 12, 15))" => 'Dec 15 2020',
      "TimeSerial(14, 30, 5)" => '14:30:05',
      "TimeValue(TimeSerial(14, 30, 5))" => '14:30:05'
    }.each do |expression, expected|
      it "formats #{expression} as '#{expected}'" do
        assert_equal expected, formatted(expression)
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
        assert_match expected, formatted(expression)
      end
    end
  end

  describe "the fixed format applies only to default formatting" do
    it "keeps an explicit format string over the fixed date format" do
      assert_equal '15.12.2020',
        formatted("DateSerial(2020, 12, 15)", format_string: 'dd.mm.yyyy')
    end

    it "does not apply the fixed format when nested inside another function" do
      # Top-level expression is '+', not Count; format inference walks to
      # [Custom], so Count's fixed integer format must not take over.
      assert_equal '$266,776.0000',
        formatted("[Measures].[Custom] + Count([Customers].[USA].Children)")
    end
  end

  # A fixed format becomes the member's format expression, so members without
  # an explicit format that reference the member inherit it through the same
  # walk that has always propagated user-set formats outward.
  describe "the fixed format propagates to referencing members" do
    it "renders a ratio of a Count member with the propagated integer format" do
      result = referencing_result(
        "Count([Customers].[USA].Children)", "[Measures].[Source] / 4"
      )
      # [Source] is 3; the walk from [R] finds its fixed '#,##0', so the
      # ratio displays rounded to '1'. Display-only - the value keeps its
      # precision for anything that computes with it.
      assert_equal 0.75, result.values[0]
      assert_equal '1', result.formatted_values[0]
    end

    # A date pattern has no numeric rendering - Format.DateFormat extends
    # FallbackFormat, which appends the pattern token verbatim for a numeric
    # value. So a member that inherits a date format but evaluates to a number
    # displays the pattern text itself. Propagation of an explicitly set format
    # has always behaved this way; a fixed format widens how often a member
    # carries a date pattern without anyone choosing it, so pin the outcome.
    it "displays the date pattern itself when a referencing member returns a number" do
      result = referencing_result(
        "DateSerial(2020, 12, 15)", "IIf(1 = 0, [Measures].[Source], 42)"
      )
      # The walk from [R] reaches [Source] first and inherits 'mmm dd yyyy', so
      # the numeric branch renders as the pattern instead of '42'.
      assert_equal 'mmm dd yyyy', result.formatted_values[0]
    end
  end

  # Parentheses are their own function call - "(x)" resolves to a
  # ResolvedFunCall wrapping ParenthesesFunDef - so format inference must look
  # through the wrapper to reach the function that dictates the format.
  # A redundant pair of parentheses must not change how a member renders.
  describe "parentheses do not hide the function from format inference" do
    # Every fixed-format strategy, so no route into the mechanism is missed:
    # the two Count implementations, the JavaFunDef @FixedFormat annotation in
    # its date, date and time, time and integer variants.
    {
      'the Count function form' => [
        "Count(Filter([Customers].[USA].Children, [Measures].[Custom] > 0))", '3'
      ],
      'the Count property form' => [
        "Filter([Customers].[USA].Children, [Measures].[Custom] > 0).Count", '3'
      ],
      'the Count INCLUDEEMPTY form' => [
        "Count(Filter([Customers].[USA].Children, [Measures].[Custom] > 0), INCLUDEEMPTY)", '3'
      ],
      'DateSerial' => ["DateSerial(2020, 12, 15)", 'Dec 15 2020'],
      'DateValue' => ["DateValue(DateSerial(2020, 12, 15))", 'Dec 15 2020'],
      'DateAdd' => ["DateAdd('d', 7, DateSerial(2020, 12, 15))", 'Dec 22 2020 00:00:00'],
      'CDate' => ["CDate(DateSerial(2020, 12, 15))", 'Dec 15 2020 00:00:00'],
      'TimeSerial' => ["TimeSerial(14, 30, 5)", '14:30:05'],
      'TimeValue' => ["TimeValue(TimeSerial(14, 30, 5))", '14:30:05'],
      'DateDiff' => [
        "DateDiff('d', DateSerial(2020, 12, 1), [Measures].[Explicit Date])", '14'
      ]
    }.each do |form, (expression, expected)|
      # Depth 0 pins the value that the enclosed forms must reproduce. Depth 2
      # and 3 cover nesting, which the parser keeps as separate calls.
      (0..3).each do |depth|
        it "formats #{form} inside #{depth} parentheses as '#{expected}'" do
          wrapped = "#{'(' * depth}#{expression}#{')' * depth}"
          assert_equal expected, formatted(wrapped)
        end
      end
    end
  end

  # The wrapper must be unwrapped only to find the function that dictates the
  # format. Everything else that parentheses can mean must keep its behaviour.
  describe "parentheses keep their meaning for every other expression" do
    it "still inherits the format of a parenthesised member reference" do
      # No function dictates a format here, so the walk finds [Custom].
      assert_equal '$266,773.0000', formatted('([Measures].[Custom])')
    end

    it "reads two parenthesised members as a tuple, not as a wrapped expression" do
      # TupleFunDef, not ParenthesesFunDef, so the unwrapping never applies.
      assert_equal '266,773', formatted('([Measures].[Unit Sales], [Time].[1997])')
    end

    it "does not apply the fixed format when a parenthesised call is an operand" do
      # The outermost call is '+', so the walk reaches [Custom] as before.
      assert_equal '$266,776.0000', formatted(
        "(Count(Filter([Customers].[USA].Children, [Measures].[Custom] > 0))) + [Measures].[Custom]"
      )
    end

    it "keeps an explicit format string over a parenthesised fixed format" do
      assert_equal '003', formatted(
        "(Count([Customers].[USA].Children))", format_string: '000'
      )
    end

    it "propagates the fixed format of a parenthesised Count to a referencing member" do
      result = referencing_result(
        "(Count([Customers].[USA].Children))", "[Measures].[Source] / 4"
      )
      assert_equal 0.75, result.values[0]
      assert_equal '1', result.formatted_values[0]
    end
  end
end
