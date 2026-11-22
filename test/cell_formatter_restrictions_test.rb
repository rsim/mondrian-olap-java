# frozen_string_literal: true

require_relative "test_helper"

# Cell formatters can be specified with the CELL_FORMATTER and CELL_FORMATTER_SCRIPT
# calculated member properties in MDX queries. The mondrian.olap.cellFormatter.allowedClasses
# and mondrian.olap.cellFormatter.scriptEnabled properties restrict which formatters may be used.
describe "Cell formatter restrictions" do
  RUBY_FORMATTER_CLASS = "rubyobj.Mondrian.OLAP.Schema.CellFormatter.Integer20DigitsUdf"

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
      assert_equal ["%020d" % 123], execute_with_formatter_class(RUBY_FORMATTER_CLASS).formatted_values
    end

    it "allows a class listed by its exact name" do
      properties.CellFormatterAllowedClasses.set("com.example.OtherFormatter, #{RUBY_FORMATTER_CLASS}")
      assert_equal ["%020d" % 123], execute_with_formatter_class(RUBY_FORMATTER_CLASS).formatted_values
    end

    it "allows a class matching a prefix entry" do
      properties.CellFormatterAllowedClasses.set("rubyobj.Mondrian.OLAP.Schema.CellFormatter.*")
      assert_equal ["%020d" % 123], execute_with_formatter_class(RUBY_FORMATTER_CLASS).formatted_values
    end

    it "rejects a class that is not listed" do
      properties.CellFormatterAllowedClasses.set("rubyobj.Mondrian.OLAP.Schema.CellFormatter.*")
      error = assert_raises(Mondrian::OLAP::Error) { execute_with_formatter_class("java.lang.String") }
      assert_match "Formatter class 'java.lang.String' for member '[Measures].[Formatted]' is not allowed " \
        "by the mondrian.olap.cellFormatter.allowedClasses property", error.root_cause_message
    end

    it "matches class names exactly when the entry has no wildcard" do
      properties.CellFormatterAllowedClasses.set(RUBY_FORMATTER_CLASS.sub(/Udf\z/, ""))
      error = assert_raises(Mondrian::OLAP::Error) { execute_with_formatter_class(RUBY_FORMATTER_CLASS) }
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
      # The ClassCastException from Class#asSubclass is the root cause.
      assert_equal "class java.lang.Object", error.root_cause_message
    end
  end

  describe "scripts" do
    it "rejects a cell formatter script when scripts are disabled" do
      properties.CellFormatterScriptEnabled.set(false)
      error = assert_raises(Mondrian::OLAP::Error) { execute_with_formatter_script('return "formatted";') }
      assert_match "Cell formatter script for member '[Measures].[Formatted]' is not allowed " \
        "because the mondrian.olap.cellFormatter.scriptEnabled property is false", error.root_cause_message
    end

    it "allows a cell formatter script when scripts are enabled" do
      skip "JavaScript engine is not available" unless javascript_engine_available?
      properties.CellFormatterScriptEnabled.set(true)
      assert_equal ["formatted"], execute_with_formatter_script('return "formatted";').formatted_values
    end

    it "still allows formatter classes when scripts are disabled" do
      properties.CellFormatterScriptEnabled.set(false)
      assert_equal ["%020d" % 123], execute_with_formatter_class(RUBY_FORMATTER_CLASS).formatted_values
    end
  end
end
