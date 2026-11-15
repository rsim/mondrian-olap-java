# frozen_string_literal: true

require_relative "test_helper"

java_import "mondrian.rolap.RolapUtil"

# LookupCube(<Cube Name>, <Expression String>[, SHARED_CONTEXT | <Dimension or Hierarchy>, ...])
# evaluates an MDX expression in another cube. The Sales and Warehouse cubes of
# FoodMart share the Store, Store Size in SQFT, Store Type, Time and Product
# dimensions, so the tests compare lookups from Sales with queries on Warehouse.
describe "LookupCube" do
  class SqlRecordingHook
    include Java::MondrianRolap::RolapUtil::ExecuteQueryHook

    attr_reader :sqls

    def initialize
      @sqls = []
    end

    def onExecuteQuery(sql)
      @sqls << sql
    end
  end

  before(:all) do
    create_olap_connection
  end

  after(:all) do
    @olap&.close
  end

  after do
    @olap.role_name = nil
  end

  def values(mdx)
    @olap.execute(mdx).values
  end

  def lookup_query(formula, rows:, columns: nil, where: nil, with: nil)
    <<~MDX
      WITH #{with}
        MEMBER [Measures].[Lookup] AS '#{formula}'
      SELECT {#{columns || "[Measures].[Lookup]"}} ON COLUMNS,
        #{rows} ON ROWS
      FROM [Sales]
      #{"WHERE #{where}" if where}
    MDX
  end

  def warehouse_query(measure, rows:, where: nil, with: nil)
    <<~MDX
      #{"WITH #{with}" if with}
      SELECT {#{measure}} ON COLUMNS,
        #{rows} ON ROWS
      FROM [Warehouse]
      #{"WHERE #{where}" if where}
    MDX
  end

  def assert_lookup_equals_warehouse(formula, rows:, measure: "[Measures].[Warehouse Sales]", where: nil, with: nil)
    expected = values(warehouse_query(measure, rows: rows, where: where, with: with))
    actual = values(lookup_query(formula, rows: rows, where: where, with: with))
    refute_empty expected.flatten.compact, "expected Warehouse values"
    # Values that are rolled up from other cached segments can differ in the last digits.
    assert_equal round_values(expected), round_values(actual)
  end

  def round_values(values)
    values.map { |value| value.is_a?(Array) ? round_values(value) : value.is_a?(Float) ? value.round(6) : value }
  end

  def flush_cube_cache(cube_name)
    connection = @olap.raw_mondrian_connection
    cache_control = connection.getCacheControl(nil)
    cube = connection.getSchema.lookupCube(cube_name, true)
    cache_control.flush(cache_control.createMeasuresRegion(cube))
  end

  def record_sql
    hook = SqlRecordingHook.new
    RolapUtil.setHook(hook)
    yield
    hook.sqls
  ensure
    RolapUtil.setHook(nil)
  end

  describe "without context mapping" do
    it "evaluates coordinates built into the expression string" do
      assert_lookup_equals_warehouse(
        'LookupCube("Warehouse", "(" + [Store].CurrentMember.UniqueName + ", [Measures].[Warehouse Sales])")',
        rows: "[Store].[USA].Children"
      )
    end

    it "evaluates the expression in the default context of the other cube" do
      total = values(warehouse_query("[Measures].[Warehouse Sales]", rows: "{[Store].[All Stores]}")).flatten.first
      actual = values(lookup_query('LookupCube("Warehouse", "[Measures].[Warehouse Sales]")',
        rows: "[Store].[USA].Children")).flatten
      assert_equal [total] * actual.size, actual
    end

    it "accepts a cube name in brackets" do
      total = values(warehouse_query("[Measures].[Warehouse Sales]", rows: "{[Store].[All Stores]}")).flatten.first
      assert_equal total, values(lookup_query('LookupCube("[Warehouse]", "[Measures].[Warehouse Sales]")',
        rows: "{[Store].[All Stores]}")).flatten.first
    end

    it "evaluates calculated members of the other cube" do
      assert_lookup_equals_warehouse(
        'LookupCube("Warehouse", "(" + [Store].CurrentMember.UniqueName + ", [Measures].[Average Warehouse Sale])")',
        rows: "[Store].[USA].Children",
        measure: "[Measures].[Average Warehouse Sale]"
      )
    end

    it "returns string values" do
      assert_equal ["All Warehouses"],
        values(lookup_query('LookupCube("Warehouse", "[Warehouse].CurrentMember.Name")',
          rows: "{[Store].[All Stores]}")).flatten
    end

    it "can be used in arithmetic" do
      total = values(warehouse_query("[Measures].[Warehouse Sales]", rows: "{[Store].[All Stores]}")).flatten.first
      actual = values(lookup_query('LookupCube("Warehouse", "[Measures].[Warehouse Sales]") * 2',
        rows: "{[Store].[All Stores]}")).flatten.first
      assert_in_delta total * 2, actual, 0.001
    end

    it "evaluates named sets of the other cube" do
      assert_equal [5], values(lookup_query('LookupCube("Warehouse", "Count([Top Sellers])")',
        rows: "{[Store].[All Stores]}")).flatten
    end
  end

  describe "with context mapping" do
    it "maps all common hierarchies with SHARED_CONTEXT" do
      assert_lookup_equals_warehouse(
        'LookupCube("Warehouse", "[Measures].[Warehouse Sales]", SHARED_CONTEXT)',
        rows: "CrossJoin([Time].[1997].Children, [Store].[USA].Children)"
      )
    end

    it "accepts SHARED_CONTEXT in any case" do
      assert_lookup_equals_warehouse(
        'LookupCube("Warehouse", "[Measures].[Warehouse Sales]", shared_context)',
        rows: "[Store].[USA].Children"
      )
    end

    it "maps product members of a deep level" do
      assert_lookup_equals_warehouse(
        'LookupCube("Warehouse", "[Measures].[Warehouse Sales]", SHARED_CONTEXT)',
        rows: "[Product].[Drink].[Alcoholic Beverages].[Beer and Wine].Children"
      )
    end

    it "maps only the listed dimensions" do
      # Time is not mapped, so every quarter row has the 1997 value of its store.
      expected = values(warehouse_query("[Measures].[Warehouse Sales]", rows: "[Store].[USA].Children"))
      actual = values(lookup_query('LookupCube("Warehouse", "[Measures].[Warehouse Sales]", [Store])',
        rows: "CrossJoin([Store].[USA].Children, [Time].[1997].Children)"))
      assert_equal expected.flat_map { |row| [row] * 4 }, actual
    end

    it "maps all hierarchies of a listed dimension" do
      assert_lookup_equals_warehouse(
        'LookupCube("Warehouse", "[Measures].[Warehouse Sales]", [Time])',
        rows: "{[Time.Weekly].[1997].[2], [Time.Weekly].[1997].[3], [Time.Weekly].[1997].[10]}"
      )
    end

    it "maps hierarchies that are evaluated at runtime" do
      assert_lookup_equals_warehouse(
        'LookupCube("Warehouse", "[Measures].[Warehouse Sales]", [Store].CurrentMember.Hierarchy, ' \
        "[Time].CurrentMember.Hierarchy)",
        rows: "CrossJoin([Time].[1997].Children, [Store].[USA].Children)"
      )
    end

    it "maps the slicer" do
      assert_lookup_equals_warehouse(
        'LookupCube("Warehouse", "[Measures].[Warehouse Sales]", SHARED_CONTEXT)',
        rows: "[Store].[USA].Children",
        where: "([Time].[1997].[Q3], [Product].[Drink])"
      )
    end

    it "keeps the context that the expression string sets" do
      expected = values(warehouse_query("[Measures].[Warehouse Sales]", rows: "[Store].[USA].Children",
        where: "[Time].[1997].[Q1]"))
      actual = values(lookup_query(
        'LookupCube("Warehouse", "([Measures].[Warehouse Sales], [Time].[1997].[Q1])", SHARED_CONTEXT)',
        rows: "[Store].[USA].Children", where: "[Time].[1997].[Q3]"))
      assert_equal expected, actual
    end

    it "maps compound slicers" do
      assert_lookup_equals_warehouse(
        'LookupCube("Warehouse", "[Measures].[Warehouse Sales]", SHARED_CONTEXT)',
        rows: "[Store].[USA].Children",
        where: "{[Time].[1997].[Q1], [Time].[1997].[Q2]}"
      )
    end

    it "maps compound slicers of several hierarchies" do
      assert_lookup_equals_warehouse(
        'LookupCube("Warehouse", "[Measures].[Warehouse Sales]", SHARED_CONTEXT)',
        rows: "{[Product].[All Products], [Product].[Drink], [Product].[Food]}",
        where: "{([Time].[1997].[Q1], [Store].[USA].[CA]), ([Time].[1997].[Q2], [Store].[USA].[OR])}"
      )
    end

    it "maps compound slicers whose hierarchies the expression overrides" do
      # The expression sets the store, so only the quarters of the slicer are aggregated.
      rows = "{[Product].[All Products], [Product].[Drink]}"
      where = "{([Time].[1997].[Q1], [Store].[USA].[CA]), ([Time].[1997].[Q2], [Store].[USA].[OR])}"
      expected = values(warehouse_query("[Measures].[WA Sales]", rows: rows, where: where,
        with: "MEMBER [Measures].[WA Sales] AS '([Measures].[Warehouse Sales], [Store].[USA].[WA])'"))
      actual = values(lookup_query(
        'LookupCube("Warehouse", "([Measures].[Warehouse Sales], [Store].[USA].[WA])", SHARED_CONTEXT)',
        rows: rows, where: where))
      refute_empty expected.flatten.compact
      assert_equal expected, actual
    end

    it "maps compound slicers to sets that the other cube filters" do
      formula = "Count(Filter([Customers].[Name].Members, [Measures].[Unit Sales] > 0))"
      where = "{[Time].[1997].[Q1].[1], [Time].[1997].[Q1].[2]}"
      expected = values(<<~MDX)
        WITH MEMBER [Measures].[Customers] AS '#{formula}'
        SELECT {[Measures].[Customers]} ON COLUMNS FROM [Sales] WHERE #{where}
      MDX
      actual = values(<<~MDX)
        WITH MEMBER [Measures].[Customers] AS 'LookupCube("Sales", "#{formula}", [Time])'
        SELECT {[Measures].[Customers]} ON COLUMNS FROM [Warehouse] WHERE #{where}
      MDX
      assert_equal expected, actual
    end

    it "maps compound slicers to dimensions that are listed" do
      assert_lookup_equals_warehouse(
        'LookupCube("Warehouse", "[Measures].[Warehouse Sales]", [Time], [Store])',
        rows: "[Store].[USA].Children",
        where: "{[Time].[1997].[Q1], [Time].[1997].[Q4]}"
      )
    end

    it "maps calculated members that aggregate a set" do
      assert_lookup_equals_warehouse(
        'LookupCube("Warehouse", "[Measures].[Warehouse Sales]", SHARED_CONTEXT)',
        rows: "CrossJoin({[Time].[H1], [Time].[1997].[Q3]}, [Store].[USA].Children)",
        with: "MEMBER [Time].[H1] AS 'Aggregate({[Time].[1997].[Q1], [Time].[1997].[Q2]})'"
      )
    end

    it "maps several calculated members that aggregate sets together with a compound slicer" do
      assert_lookup_equals_warehouse(
        'LookupCube("Warehouse", "[Measures].[Warehouse Sales]", SHARED_CONTEXT)',
        rows: "{[Time].[H1], [Time].[H2]}",
        where: "{[Store].[USA].[CA], [Store].[USA].[OR]}",
        with: "MEMBER [Time].[H1] AS 'Aggregate({[Time].[1997].[Q1], [Time].[1997].[Q2]})' " \
          "MEMBER [Time].[H2] AS 'Aggregate({[Time].[1997].[Q3], [Time].[1997].[Q4]})'"
      )
    end

    it "maps calculated members that aggregate tuples of several hierarchies" do
      assert_lookup_equals_warehouse(
        'LookupCube("Warehouse", "[Measures].[Warehouse Sales]", SHARED_CONTEXT)',
        rows: "{[Time].[Mixed]}",
        with: "MEMBER [Time].[Mixed] AS " \
          "'Aggregate({([Time].[1997].[Q1], [Store].[USA].[CA]), ([Time].[1997].[Q2], [Store].[USA].[WA])})'"
      )
    end

    it "maps calculated members that add members" do
      assert_lookup_equals_warehouse(
        'LookupCube("Warehouse", "[Measures].[Warehouse Sales]", SHARED_CONTEXT)',
        rows: "CrossJoin({[Time].[Q1 and Q4]}, [Store].[USA].Children)",
        with: "MEMBER [Time].[Q1 and Q4] AS '[Time].[1997].[Q1] + [Time].[1997].[Q4]'"
      )
    end

    it "maps calculated members that return a member" do
      assert_lookup_equals_warehouse(
        'LookupCube("Warehouse", "[Measures].[Warehouse Sales]", SHARED_CONTEXT)',
        rows: "CrossJoin({[Time].[Last Quarter]}, [Store].[USA].Children)",
        with: "MEMBER [Time].[Last Quarter] AS '[Time].[1997].LastChild'"
      )
    end

    it "returns empty for members that are not in the other cube" do
      # The Sales cube has no [Warehouse] dimension, and the Warehouse cube has no [Customers]
      # dimension, so SHARED_CONTEXT maps neither of them.
      expected = values(warehouse_query("[Measures].[Warehouse Sales]", rows: "{[Store].[USA]}")).flatten
      actual = values(lookup_query('LookupCube("Warehouse", "[Measures].[Warehouse Sales]", SHARED_CONTEXT)',
        rows: "{[Customers].[USA].[CA]}", where: "[Store].[USA]")).flatten
      assert_equal expected, actual
    end

    it "keeps members that have values only in the other cube in NON EMPTY rows" do
      rows = "[Product].[Food].[Baking Goods].[Jams and Jellies].[Jelly].[CDR].Children"
      expected = @olap.execute(<<~MDX).row_names
        SELECT {[Measures].[Warehouse Sales]} ON COLUMNS, NON EMPTY #{rows} ON ROWS FROM [Warehouse]
      MDX
      assert_includes expected, "CDR Grape Jelly"
      actual = @olap.execute(<<~MDX).row_names
        WITH MEMBER [Measures].[Lookup] AS 'LookupCube("Warehouse", "[Measures].[Warehouse Sales]", SHARED_CONTEXT)'
        SELECT {[Measures].[Lookup]} ON COLUMNS, NON EMPTY #{rows} ON ROWS FROM [Sales]
      MDX
      assert_equal expected, actual
    end
  end

  describe "cell batching" do
    it "loads the cells of the other cube in batches, not one per row" do
      flush_cube_cache("Warehouse")
      sqls = record_sql do
        values(lookup_query('LookupCube("Warehouse", "[Measures].[Warehouse Sales]", SHARED_CONTEXT)',
          rows: "CrossJoin([Time].[1997].Children, [Store].[USA].[CA].Children)"))
      end
      warehouse_sqls = sqls.select { |sql| sql =~ /inventory_fact_1997/ }
      refute_empty warehouse_sqls
      assert_operator warehouse_sqls.size, :<=, 2, warehouse_sqls.join("\n\n")
    end

    it "loads the cells of a compound slicer in one batch" do
      flush_cube_cache("Warehouse")
      sqls = record_sql do
        values(lookup_query('LookupCube("Warehouse", "[Measures].[Warehouse Sales]", SHARED_CONTEXT)',
          rows: "[Store].[USA].[CA].Children",
          where: "{[Time].[1997].[Q1].[1], [Time].[1997].[Q1].[2], [Time].[1997].[Q2].[5]}"))
      end
      warehouse_sqls = sqls.select { |sql| sql =~ /inventory_fact_1997/ }
      refute_empty warehouse_sqls
      assert_operator warehouse_sqls.size, :<=, 2, warehouse_sqls.join("\n\n")
    end

    it "loads the cells of the other cube again after the cache is flushed" do
      mdx = lookup_query('LookupCube("Warehouse", "[Measures].[Warehouse Sales]", SHARED_CONTEXT)',
        rows: "[Store].[USA].Children")
      # Run the query in each thread of the query executor, so that the next query runs in
      # a thread that has run it before.
      threads = Java::MondrianOlap::MondrianProperties.instance.RolapConnectionShepherdNbThreads.get
      (threads * 2).times { values(mdx) }
      flush_cube_cache("Warehouse")
      sqls = record_sql { values(mdx) }
      refute_empty sqls.grep(/inventory_fact_1997/)
    end
  end

  describe "errors" do
    it "fails for an unknown cube" do
      assert_expression_raises @olap, 'LookupCube("Unknown", "[Measures].[Unit Sales]")',
        "MDX cube 'Unknown' not found"
    end

    it "fails for a cube that the role cannot access" do
      @olap.role_name = "California manager"
      assert_expression_raises @olap, 'LookupCube("Warehouse", "[Measures].[Warehouse Sales]")',
        "MDX cube 'Warehouse' not found"
    end

    it "fails for an invalid expression" do
      assert_expression_raises @olap, 'LookupCube("Warehouse", "[Measures].[Unit Sales]")',
        /LookupCube failed to compile expression '\[Measures\]\.\[Unit Sales\]' in cube 'Warehouse'/
    end

    it "fails for a third argument other than SHARED_CONTEXT" do
      assert_expression_raises @olap,
        'LookupCube("Warehouse", "[Measures].[Warehouse Sales]", 1 = 1)',
        "No function matches signature 'LookupCube(<String>, <String>, <Logical Expression>)'"
    end

    it "fails for an expression that returns a set" do
      assert_expression_raises @olap, 'LookupCube("Warehouse", "[Store].Children")',
        "expression must return a value, not a set"
    end

    it "fails for a listed hierarchy that the other cube does not have" do
      assert_expression_raises @olap,
        'LookupCube("Warehouse", "[Measures].[Warehouse Sales]", [Customers].CurrentMember.Hierarchy)',
        "LookupCube cannot map hierarchy '[Customers]' because it does not exist in cube 'Warehouse'"
    end

    it "fails for a calculated member that does not aggregate members" do
      mdx = lookup_query('LookupCube("Warehouse", "[Measures].[Warehouse Sales]", SHARED_CONTEXT)',
        rows: "{[Time].[Constant]}", with: "MEMBER [Time].[Constant] AS '1'")
      assert_query_raises @olap, mdx,
        "LookupCube cannot map calculated member '[Time].[Constant]' of hierarchy '[Time]' to cube 'Warehouse'"
    end

    it "does not see calculated members of the query in the other cube" do
      mdx = <<~MDX
        WITH MEMBER [Measures].[Query Member] AS 'LookupCube("Sales", "[Measures].[Query Member]")'
        SELECT {[Measures].[Query Member]} ON COLUMNS FROM [Sales]
      MDX
      assert_query_raises @olap, mdx,
        "LookupCube failed to compile expression '[Measures].[Query Member]' in cube 'Sales': " \
        "MDX object '[Measures].[Query Member]' not found in cube 'Sales'"
    end
  end

  describe "query limits while the expression is compiled" do
    class TimeoutOnSqlHook
      include Java::MondrianRolap::RolapUtil::ExecuteQueryHook

      def onExecuteQuery(sql)
        raise Java::MondrianOlap::QueryTimeoutException.new("Query timeout of 1 seconds reached")
      end
    end

    before(:all) do
      # A schema of its own, so that the members of the expression are not cached yet
      # and compiling the expression runs SQL.
      schema = define_schema do
        cube "Source" do
          table "sales_fact_1997"
          measure "Unit Sales", column: "unit_sales", aggregator: "sum"
        end
        cube "Target" do
          table "sales_fact_1997"
          dimension "Customers", foreign_key: "customer_id" do
            hierarchy has_all: true, primary_key: "customer_id" do
              table "customer"
              level "Country", column: "country", unique_members: true
            end
          end
          measure "Unit Sales", column: "unit_sales", aggregator: "sum"
        end
      end
      @limit_olap = Mondrian::OLAP::Connection.create(CONNECTION_PARAMS.except(:catalog).merge(schema: schema))
    end

    after(:all) do
      @limit_olap&.close
    end

    it "keeps the query timeout as the root cause" do
      RolapUtil.setHook(TimeoutOnSqlHook.new)
      error = assert_raises(Mondrian::OLAP::Error) do
        @limit_olap.execute(<<~MDX)
          WITH MEMBER [Measures].[Lookup] AS 'LookupCube("Target", "([Measures].[Unit Sales], [Customers].[USA])")'
          SELECT {[Measures].[Lookup]} ON COLUMNS FROM [Source]
        MDX
      end
      assert_kind_of Java::MondrianOlap::QueryTimeoutException, error.root_cause
    ensure
      RolapUtil.setHook(nil)
    end
  end

  describe "calculated members of two cubes that look each other up" do
    before(:all) do
      schema = define_schema do
        cube "First" do
          table "sales_fact_1997"
          measure "Unit Sales", column: "unit_sales", aggregator: "sum"
          calculated_member "Second Value", dimension: "Measures",
            formula: 'LookupCube("Second", "[Measures].[First Value]")'
        end
        cube "Second" do
          table "sales_fact_1997"
          measure "Unit Sales", column: "unit_sales", aggregator: "sum"
          calculated_member "First Value", dimension: "Measures",
            formula: 'LookupCube("First", "[Measures].[Second Value]")'
          calculated_member "Unit Sales Of First", dimension: "Measures",
            formula: 'LookupCube("First", "[Measures].[Unit Sales]")'
        end
      end
      @cycle_olap = Mondrian::OLAP::Connection.create(CONNECTION_PARAMS.except(:catalog).merge(schema: schema))
    end

    after(:all) do
      @cycle_olap&.close
    end

    it "evaluates calculated members that use LookupCube" do
      assert_equal @cycle_olap.execute("SELECT {[Measures].[Unit Sales]} ON COLUMNS FROM [First]").values,
        @cycle_olap.execute("SELECT {[Measures].[Unit Sales Of First]} ON COLUMNS FROM [Second]").values
    end

    it "fails for a cycle" do
      assert_query_raises @cycle_olap, "SELECT {[Measures].[Second Value]} ON COLUMNS FROM [First]",
        "LookupCube calls are nested more than 16 levels deep"
    end
  end
end
