# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"
require "tmpdir"

# Cell formatters can be specified with the CELL_FORMATTER and CELL_FORMATTER_SCRIPT
# calculated member properties in MDX queries. The mondrian.olap.cellFormatter.allowedClasses
# and mondrian.olap.cellFormatter.scriptEnabled properties restrict which formatters may be used.
describe "Cell formatter restrictions" do
  def ruby_formatter_class
    "rubyobj.Mondrian.OLAP.Schema.CellFormatter.Integer20DigitsUdf"
  end

  def properties
    Java::MondrianOlap::MondrianProperties.instance
  end

  before(:all) do
    # Defining the shared formatter generates its Java class.
    define_schema do
      user_defined_cell_formatter "Integer20Digits" do
        ruby :shared do |value|
          "%020d" % value
        end
      end
    end
    create_olap_connection
  end

  after(:all) do
    @olap&.close
  end

  before do
    @original_allowed_classes = properties.CellFormatterAllowedClasses.get
    @original_script_enabled = properties.CellFormatterScriptEnabled.get
  end

  after do
    properties.CellFormatterAllowedClasses.set(@original_allowed_classes)
    properties.CellFormatterScriptEnabled.set(@original_script_enabled)
  end

  def execute_with_formatter(formatter_properties)
    @olap.execute(<<~MDX)
      WITH MEMBER [Measures].[Formatted] AS '123', #{formatter_properties}
      SELECT {[Measures].[Formatted]} ON COLUMNS
      FROM [Sales]
    MDX
  end

  def execute_with_formatter_class(class_name)
    execute_with_formatter("CELL_FORMATTER = '#{class_name}'")
  end

  def execute_with_formatter_script(script)
    execute_with_formatter("CELL_FORMATTER_SCRIPT_LANGUAGE = 'JavaScript', CELL_FORMATTER_SCRIPT = '#{script}'")
  end

  def javascript_engine_available?
    !javax.script.ScriptEngineManager.new.getEngineByName("JavaScript").nil?
  end

  describe "allowed classes" do
    it "allows any class when the property is empty" do
      properties.CellFormatterAllowedClasses.set("")
      assert_equal ["%020d" % 123], execute_with_formatter_class(ruby_formatter_class).formatted_values
    end

    it "allows a class listed by its exact name" do
      properties.CellFormatterAllowedClasses.set("com.example.OtherFormatter, #{ruby_formatter_class}")
      assert_equal ["%020d" % 123], execute_with_formatter_class(ruby_formatter_class).formatted_values
    end

    it "allows a class matching a prefix entry" do
      properties.CellFormatterAllowedClasses.set("rubyobj.Mondrian.OLAP.Schema.CellFormatter.*")
      assert_equal ["%020d" % 123], execute_with_formatter_class(ruby_formatter_class).formatted_values
    end

    it "rejects a class that is not listed" do
      properties.CellFormatterAllowedClasses.set("rubyobj.Mondrian.OLAP.Schema.CellFormatter.*")
      error = assert_raises(Mondrian::OLAP::Error) { execute_with_formatter_class("java.lang.String") }
      assert_match "Formatter class 'java.lang.String' for member '[Measures].[Formatted]' is not allowed " \
        "by the mondrian.olap.cellFormatter.allowedClasses property", error.root_cause_message
    end

    it "matches class names exactly when the entry has no wildcard" do
      properties.CellFormatterAllowedClasses.set(ruby_formatter_class.sub(/Udf\z/, ""))
      error = assert_raises(Mondrian::OLAP::Error) { execute_with_formatter_class(ruby_formatter_class) }
      assert_match "is not allowed by the mondrian.olap.cellFormatter.allowedClasses property", error.root_cause_message
    end

    it "rejects a schema measure formatter that is not listed" do
      properties.CellFormatterAllowedClasses.set("rubyobj.Mondrian.OLAP.Schema.CellFormatter.*")
      schema = define_schema do
        cube "Sales" do
          table "sales_fact_1997"
          measure "Unit Sales", column: "unit_sales", aggregator: "sum" do
            cell_formatter nil, class_name: "java.lang.String"
          end
        end
      end
      error = assert_raises(Mondrian::OLAP::Error) do
        Mondrian::OLAP::Connection.create(CONNECTION_PARAMS.except(:catalog).merge(schema: schema)).close
      end
      assert_match "Formatter class 'java.lang.String' for member '[Measures].[Unit Sales]' is not allowed", error.root_cause_message
    end

    it "allows a non-shared Ruby formatter matching the rubyobj prefix" do
      properties.CellFormatterAllowedClasses.set("rubyobj.*")
      schema = define_schema do
        cube "Sales" do
          table "sales_fact_1997"
          measure "Unit Sales", column: "unit_sales", aggregator: "sum" do
            cell_formatter do
              ruby do |value|
                "formatted"
              end
            end
          end
        end
      end
      olap = Mondrian::OLAP::Connection.create(CONNECTION_PARAMS.except(:catalog).merge(schema: schema))
      begin
        result = olap.execute("SELECT {[Measures].[Unit Sales]} ON COLUMNS FROM [Sales]")
        assert_equal ["formatted"], result.formatted_values
      ensure
        olap.close
      end
    end

    it "rejects a class that does not implement the cell formatter interface" do
      properties.CellFormatterAllowedClasses.set("")
      error = assert_raises(Mondrian::OLAP::Error) { execute_with_formatter_class("java.lang.Object") }
      # The ClassCastException from FormatterFactory is the root cause.
      assert_equal "class java.lang.Object does not implement interface mondrian.spi.CellFormatter",
        error.root_cause_message
    end
  end

  # Fixture classes record their static initializer and constructor runs in System properties,
  # so checking them does not initialize the class. Each fixture is requested by one test only,
  # as a class stays initialized after its first use.
  describe "class initialization" do
    def fixture_package
      "cellformattertest"
    end

    # Fixture class names, mapped to whether the class implements CellFormatter.
    def fixtures
      {"WrongTypeFixture" => false, "NotAllowedFormatterFixture" => true, "AllowedFormatterFixture" => true}
    end

    def fixture_source(class_name, implements_cell_formatter)
      side_effect = ->(event) { %(System.setProperty("#{fixture_package}.#{class_name}.#{event}", "true");) }
      <<~JAVA
        package #{fixture_package};
        public class #{class_name}#{" implements mondrian.spi.CellFormatter" if implements_cell_formatter} {
          static { #{side_effect.call("initialized")} }
          public #{class_name}() { #{side_effect.call("constructed")} }
          #{'public String formatCell(Object value) { return "fixture"; }' if implements_cell_formatter}
        }
      JAVA
    end

    before(:all) do
      @compiler = javax.tools.ToolProvider.getSystemJavaCompiler
      if @compiler
        @fixture_dir = Dir.mktmpdir
        source_dir = File.join(@fixture_dir, fixture_package)
        Dir.mkdir(source_dir)
        source_files = fixtures.map do |class_name, implements_cell_formatter|
          File.join(source_dir, "#{class_name}.java").tap do |path|
            File.write(path, fixture_source(class_name, implements_cell_formatter))
          end
        end
        mondrian_jar = Java::MondrianSpi::CellFormatter.java_class.to_java.getProtectionDomain.getCodeSource.getLocation.getPath
        exit_code = @compiler.run(nil, nil, nil, ["-cp", mondrian_jar, "-d", @fixture_dir, *source_files].to_java(:string))
        raise "Failed to compile cell formatter fixtures" unless exit_code == 0
        $CLASSPATH << "#{@fixture_dir}/"
      end
    end

    after(:all) do
      FileUtils.rm_rf(@fixture_dir) if @fixture_dir
    end

    before do
      skip "Java compiler is not available" unless @compiler
    end

    def fixture_class(class_name)
      "#{fixture_package}.#{class_name}"
    end

    def fixture_event?(class_name, event)
      java.lang.System.getProperty("#{fixture_package}.#{class_name}.#{event}") == "true"
    end

    it "initializes and constructs an allowed formatter class" do
      properties.CellFormatterAllowedClasses.set(fixture_class("AllowedFormatterFixture"))
      assert_equal ["fixture"], execute_with_formatter_class(fixture_class("AllowedFormatterFixture")).formatted_values
      assert_equal true, fixture_event?("AllowedFormatterFixture", "initialized")
      assert_equal true, fixture_event?("AllowedFormatterFixture", "constructed")
    end

    it "does not initialize or construct a class that does not implement the interface" do
      properties.CellFormatterAllowedClasses.set("")
      error = assert_raises(Mondrian::OLAP::Error) { execute_with_formatter_class(fixture_class("WrongTypeFixture")) }
      assert_match "does not implement interface mondrian.spi.CellFormatter", error.root_cause_message
      assert_equal false, fixture_event?("WrongTypeFixture", "initialized")
      assert_equal false, fixture_event?("WrongTypeFixture", "constructed")
    end

    it "does not initialize or construct a formatter class that is not allowed" do
      properties.CellFormatterAllowedClasses.set("rubyobj.*")
      error = assert_raises(Mondrian::OLAP::Error) do
        execute_with_formatter_class(fixture_class("NotAllowedFormatterFixture"))
      end
      assert_match "is not allowed by the mondrian.olap.cellFormatter.allowedClasses property", error.root_cause_message
      assert_equal false, fixture_event?("NotAllowedFormatterFixture", "initialized")
      assert_equal false, fixture_event?("NotAllowedFormatterFixture", "constructed")
    end
  end

  describe "scripts" do
    it "rejects a cell formatter script when scripts are disabled" do
      properties.CellFormatterScriptEnabled.set(false)
      error = assert_raises(Mondrian::OLAP::Error) { execute_with_formatter_script('return "formatted";') }
      assert_match "Cell formatter script for member '[Measures].[Formatted]' is not allowed " \
        "because the mondrian.olap.cellFormatter.scriptEnabled property is false", error.root_cause_message
    end

    it "rejects a schema measure formatter script when scripts are disabled" do
      properties.CellFormatterScriptEnabled.set(false)
      schema = define_schema do
        cube "Sales" do
          table "sales_fact_1997"
          measure "Unit Sales", column: "unit_sales", aggregator: "sum" do
            cell_formatter do
              script 'return "formatted";', language: "JavaScript"
            end
          end
        end
      end
      error = assert_raises(Mondrian::OLAP::Error) do
        Mondrian::OLAP::Connection.create(CONNECTION_PARAMS.except(:catalog).merge(schema: schema)).close
      end
      assert_match "Cell formatter script for member '[Measures].[Unit Sales]' is not allowed", error.root_cause_message
    end

    it "allows a cell formatter script when scripts are enabled" do
      skip "JavaScript engine is not available" unless javascript_engine_available?
      properties.CellFormatterScriptEnabled.set(true)
      assert_equal ["formatted"], execute_with_formatter_script('return "formatted";').formatted_values
    end

    it "still allows formatter classes when scripts are disabled" do
      properties.CellFormatterScriptEnabled.set(false)
      assert_equal ["%020d" % 123], execute_with_formatter_class(ruby_formatter_class).formatted_values
    end
  end
end
