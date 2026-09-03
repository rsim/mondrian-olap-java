# frozen_string_literal: true

require_relative "test_helper"

# CDate parses a string with java.text.DateFormat of the JVM default locale.
# The patterns of a locale are not the same in every Java version. The same
# saved MDX expression therefore gave a different result, or an error, after a
# Java upgrade. CDate now tries a fixed set of patterns first. These tests must
# give the same result on every Java version and with every default locale.
describe "CDate parses strings the same way on every Java version" do
  before(:all) do
    @default_format_locale = java.util.Locale.getDefault(java.util.Locale::Category::FORMAT)
    create_olap_connection
    @olap.locale = 'en'
  end

  after(:all) do
    java.util.Locale.setDefault(java.util.Locale::Category::FORMAT, @default_format_locale)
    @olap&.close
  end

  def formatted(expression)
    @olap.from('Sales').
      with_member('[Measures].[D]').as("Format(#{expression}, 'mmm dd yyyy hh:mm:ss')").
      columns('[Measures].[D]').execute.formatted_values.first
  end

  {
    "CDate('2025-05-23')" => 'May 23 2025 00:00:00',
    "CDate('2025-05-23 14:30:00')" => 'May 23 2025 14:30:00',
    "CDate('Nov 18 2015')" => 'Nov 18 2015 00:00:00',
    "CDate('Nov 18, 2015')" => 'Nov 18 2015 00:00:00',
    "CDate('Nov 18 2015 14:30:00')" => 'Nov 18 2015 14:30:00',
    # Java 9 and later put a comma between the date and the time.
    "CDate('Nov 18, 2015, 2:30:00 PM')" => 'Nov 18 2015 14:30:00',
    "CDate('Nov 18, 2015, 14:30:00')" => 'Nov 18 2015 14:30:00',
    # A two-digit year means the current century, as it does in VBA.
    "CDate('Nov 18, 15')" => 'Nov 18 2015 00:00:00',
    "CDate('4:35:47 PM')" => 'Jan 01 1970 16:35:47',
    "CDate('14:30:00')" => 'Jan 01 1970 14:30:00',
    # A Date argument never reaches the string parsing.
    "CDate(DateSerial(2020, 12, 15))" => 'Dec 15 2020 00:00:00'
  }.each do |expression, expected|
    it "formats #{expression} as '#{expected}'" do
      assert_equal expected, formatted(expression)
    end

    it "formats #{expression} the same way with a non-English default locale" do
      java.util.Locale.setDefault(java.util.Locale::Category::FORMAT, java.util.Locale::GERMANY)
      assert_equal expected, formatted(expression)
    ensure
      java.util.Locale.setDefault(java.util.Locale::Category::FORMAT, @default_format_locale)
    end
  end

  # Java 20 and later format AM and PM after a narrow no-break space (CLDR 42),
  # so a string saved on such a JVM carries that character.
  it "parses a time that holds a narrow no-break space before PM" do
    assert_equal 'Jan 01 1970 16:35:47', formatted("CDate('4:35:47\u202FPM')")
  end

  # The locale formats stay as a fallback for a shape that no fixed pattern
  # accepts. Build the input with the same locale DateFormat that reads it back.
  # The fallback gets the raw string, so it still matches a Java 20 or later
  # pattern, which holds the narrow no-break space itself. This test turns red
  # if anybody normalises the string before the fallback.
  it "keeps the time of a locale date and time that no fixed pattern accepts" do
    canada = java.util.Locale::CANADA
    calendar = java.util.Calendar.getInstance
    calendar.clear
    calendar.set(1969, 1, 12, 16, 35, 47)
    input = java.text.DateFormat.getDateTimeInstance(
      java.text.DateFormat::DEFAULT, java.text.DateFormat::DEFAULT, canada
    ).format(calendar.getTime)
    java.util.Locale.setDefault(java.util.Locale::Category::FORMAT, canada)
    assert_equal 'Feb 12 1969 16:35:47', formatted("CDate('#{input}')")
  ensure
    java.util.Locale.setDefault(java.util.Locale::Category::FORMAT, @default_format_locale)
  end

  it "reports an error for a string that no pattern accepts" do
    assert_match(/must be formatted correctly/, formatted("CDate('not a date')"))
  end

  # The fixed patterns are strict, so a day outside the month is an error and
  # not a roll-over into the next month.
  it "reports an error for a date that does not exist" do
    assert_match(/must be formatted correctly/, formatted("CDate('2025-02-30')"))
  end
end
