# frozen_string_literal: true

require_relative "test_helper"

# TupleExpMemoComparator caches the sort key value of each tuple for the whole sort.
# The upstream cache was bounded to 100000 entries. In a larger tuple sort it evicted
# values and evaluated them again. A sort key that uses Now() returns a different value
# on each evaluation, so Order failed with "Comparison method violates its general contract!".
describe "Order tuples by a sort key that changes on each evaluation" do
  before(:all) do
    schema = define_schema do
      cube 'Sales' do
        table 'sales_fact_1997'
        dimension 'Customers', foreign_key: 'customer_id' do
          hierarchy has_all: true, all_member_name: 'All Customers', primary_key: 'customer_id' do
            table 'customer'
            level 'Name', column: 'customer_id', name_column: 'fullname', unique_members: true
          end
        end
        dimension 'Promotion Media', foreign_key: 'promotion_id' do
          hierarchy has_all: true, all_member_name: 'All Media', primary_key: 'promotion_id' do
            table 'promotion'
            level 'Media Type', column: 'media_type', unique_members: true
          end
        end
        measure 'Unit Sales', column: 'unit_sales', aggregator: 'sum'
      end
      # Returns a larger value on each call, like DateDiffWorkdays(..., Now()).
      user_defined_function 'IncreasingValue' do
        ruby do
          parameters :numeric
          returns :numeric
          def call(_value)
            @count = (@count || 0) + 1
          end
        end
      end
    end
    @olap = Mondrian::OLAP::Connection.create(CONNECTION_PARAMS.except(:catalog).merge(schema: schema))
  end

  after(:all) do
    @olap&.close
  end

  it "sorts more than 100000 tuples" do
    # 10281 customers x 14 media types = 143934 tuples, more than the former 100000 cache limit.
    mdx = <<~MDX
      WITH MEMBER [Measures].[Increasing] AS 'IncreasingValue([Measures].[Unit Sales])'
      SELECT {[Measures].[Unit Sales]} ON COLUMNS,
      Head(Order(CrossJoin([Customers].[Name].Members, [Promotion Media].[Media Type].Members),
        [Measures].[Increasing], BDESC), 3) ON ROWS
      FROM [Sales]
    MDX
    assert_equal 3, @olap.execute(mdx).row_names.size
  end
end
