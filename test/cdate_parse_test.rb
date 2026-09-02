# frozen_string_literal: true

require_relative "test_helper"

# CDate parses a string with java.text.DateFormat of the JVM default locale.
# The patterns of a locale are not the same in every Java version, so the same
# saved MDX expression gave a different result, or an error, after a Java
# upgrade. CDate now tries a fixed set of patterns first. These tests must give
# the same result on every Java version and with every default locale.
describe "CDate parses strings the same way on every Java version" do
  before(:all) do
    create_olap_connection
    @olap.locale = 'en'
    @default_format_locale = java.util.Locale.getDefault(java.util.Locale::Category::FORMAT)
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

  it "reports an error for a string that no pattern accepts" do
    assert_match(/must be formatted correctly/, formatted("CDate('not a date')"))
  end
end
