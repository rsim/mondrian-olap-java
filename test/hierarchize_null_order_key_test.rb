# frozen_string_literal: true

require_relative "test_helper"

java_import "mondrian.olap.fun.sort.Sorter"
java_import "mondrian.rolap.RolapUtil"

# Regression test for the member comparator total-order bug.
#
# Sorter.compareSiblingMembers used to return 0 for two *distinct* members whose order key is
# the NULL sentinel RolapUtil.sqlNullValue (e.g. an Issue Epic whose epic_id ordinal column is
# NULL because the epic is not imported). Returning 0 for distinct members breaks the total
# order that Sorter.compareHierarchically must impose, so hierarchize-sorting their children
# either failed with "Comparison method violates its general contract!" or produced a
# non-hierarchical order (children not grouped under their parent).
#
# The fix compares NULL order keys explicitly and falls through to the ordinal / member
# tie-break when order keys compare as equal, so distinct members never compare as equal.
describe "Sorter comparator with NULL order keys" do
  # Minimal mondrian.olap.Member stub exercising only what the comparator reads.
  class DummyMember
    include Java::mondrian.olap.Member

    attr_reader :parent

    def initialize(order_key:, ordinal:, name:, parent: nil, depth: 0)
      @order_key = order_key
      @ordinal = ordinal
      @name = name
      @parent = parent
      @depth = depth
    end

    def isCalculatedInQuery; false; end
    def getOrderKey; @order_key; end
    def getOrdinal; @ordinal; end
    def getDepth; @depth; end
    def getParentMember; @parent; end
    def compareTo(other); @ordinal <=> other.getOrdinal; end
    def equals(other); equal?(other); end
    def hashCode; object_id; end
    def to_s; @name; end
  end

  let(:null_key) { RolapUtil.sqlNullValue }

  it "imposes a total order on two distinct members that both have a NULL order key" do
    a = DummyMember.new(order_key: null_key, ordinal: 1, name: "A")
    b = DummyMember.new(order_key: null_key, ordinal: 2, name: "B")

    # The crux of the bug: the old code returned 0 here, collapsing distinct members.
    refute_equal 0, Sorter.compareSiblingMembers(a, b)
    # Antisymmetric and self-consistent.
    assert_equal(-Sorter.compareSiblingMembers(a, b), Sorter.compareSiblingMembers(b, a))
    assert_equal 0, Sorter.compareSiblingMembers(a, a)
  end

  it "collates a NULL order key before a non-NULL key" do
    null_member = DummyMember.new(order_key: null_key, ordinal: 5, name: "null")
    real_member = DummyMember.new(order_key: java.lang.Integer.new(1), ordinal: 1, name: "real")

    assert_operator Sorter.compareSiblingMembers(null_member, real_member), :<, 0
    assert_operator Sorter.compareSiblingMembers(real_member, null_member), :>, 0
  end

  it "hierarchize-sorts children of NULL-order-key parents into a valid hierarchical order" do
    # Eight sibling parents all with a NULL order key, ten children each with a real key.
    parents = Array.new(8) { |i| DummyMember.new(order_key: null_key, ordinal: i, name: "P#{i}") }
    children = parents.each_with_index.flat_map do |parent, pi|
      Array.new(10) do |ci|
        key = pi * 100 + ci
        DummyMember.new(order_key: java.lang.Integer.new(key), ordinal: key, name: "P#{pi}C#{ci}",
          parent: parent, depth: 1)
      end
    end
    # Scramble so the broken comparator (parents comparing as equal) can no longer regroup.
    shuffled_children = children.shuffle(random: Random.new(12345))

    list = java.util.ArrayList.new
    shuffled_children.each { |member| list.add(member) }
    # With the bug this raised IllegalArgumentException or produced a scattered order.
    java.util.Collections.sort(list) { |x, y| Sorter.compareHierarchically(x, y, false) }

    # Every parent's children must end up in a single contiguous block.
    contiguous_parent_ids = list.to_a.map(&:parent).chunk { |parent| parent.object_id }.map(&:first)
    assert_equal contiguous_parent_ids.length, contiguous_parent_ids.uniq.length,
      "children are not grouped contiguously by parent after hierarchize"
  end
end
