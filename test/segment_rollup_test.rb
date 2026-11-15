# frozen_string_literal: true

require_relative "test_helper"

java_import "mondrian.olap.Util"
java_import "mondrian.util.ArraySortedSet"

# SegmentBuilder.rollup intersects the kept column values of its source segments with
# Util.intersect, which lost common values when String.compareTo returned more than 1.
describe "Segment rollup" do
  before(:all) do
    create_olap_connection
  end

  after(:all) do
    @olap&.close
  end

  def string_set(*values)
    ArraySortedSet.new(values.to_java(:string))
  end

  def flush_warehouse_segments
    connection = @olap.raw_mondrian_connection
    cache_control = connection.getCacheControl(nil)
    cube = connection.getSchema.lookupCube("Warehouse", true)
    cache_control.flush(cache_control.createMeasuresRegion(cube))
  end

  def warehouse_sales(rows)
    @olap.execute(<<~MDX).values
      SELECT {[Measures].[Warehouse Sales]} ON COLUMNS,
             #{rows} ON ROWS
      FROM [Warehouse]
    MDX
  end

  it "intersects sorted sets whose values differ by more than one character" do
    assert_equal %w[WA], Util.intersect(string_set("WA"), string_set("CA", "OR", "WA")).to_a
    assert_equal %w[WA], Util.intersect(string_set("CA", "OR", "WA"), string_set("WA")).to_a
    assert_equal %w[CA WA], Util.intersect(string_set("AA", "CA", "WA"), string_set("CA", "OR", "WA")).to_a
  end

  it "rolls up segments with different kept column values" do
    # Drop the cached segments of the cube, so that only the segments below are cached.
    flush_warehouse_segments

    # Cache store_state x quarter segments that together cover all quarters of [WA], each
    # with a different store_state value list.
    warehouse_sales("CrossJoin({[Store].[USA].[WA]}, {[Time].[1997].[Q2], [Time].[1997].[Q3]})")
    warehouse_sales("CrossJoin([Store].[USA].Children, {[Time].[1997].[Q1]})")
    warehouse_sales("CrossJoin({[Store].[USA].[WA]}, {[Time].[1997].[Q4]})")

    rolled_up = warehouse_sales("[Store].[USA].Children")

    flush_warehouse_segments
    assert_equal warehouse_sales("[Store].[USA].Children"), rolled_up
  end

  it "rolls up segments whose kept column values a segment narrows" do
    flush_warehouse_segments
    expected = warehouse_sales("[Store].[USA].Children")

    # Only the segment of [WA] has Q1, so a rollup of these segments has only [WA].
    flush_warehouse_segments
    warehouse_sales("CrossJoin([Store].[USA].Children, {[Time].[1997].[Q4]})")
    warehouse_sales("CrossJoin({[Store].[USA].[WA]}, {[Time].[1997].[Q1], [Time].[1997].[Q2]})")
    warehouse_sales("CrossJoin([Store].[USA].Children, {[Time].[1997].[Q2], [Time].[1997].[Q3]})")
    warehouse_sales("{[Store].[USA].[WA]}")

    assert_equal expected, warehouse_sales("[Store].[USA].Children")
  end
end
