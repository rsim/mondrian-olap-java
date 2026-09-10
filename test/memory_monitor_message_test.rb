# frozen_string_literal: true

require_relative "test_helper"

# A MemoryMonitor that notifies the listener when the query registers it.
# RolapConnection#executeInternal calls addListener and then checkCancelOrTimeout, so the
# notification needs no real memory pressure and the test stays deterministic.
class ImmediateMemoryMonitor
  include Java::MondrianUtil::MemoryMonitor

  USED_MEMORY = 180_933_521_344
  MAX_MEMORY = 193_273_528_320

  def addListener(listener, threshold_percentage = 0)
    listener.memoryUsageNotification(USED_MEMORY, MAX_MEMORY)
    true
  end

  def updateListenerThreshold(listener, percentage); end

  def removeListener(listener)
    true
  end

  def removeAllListener; end

  def getMaxMemory
    MAX_MEMORY
  end

  def getUsedMemory
    USED_MEMORY
  end
end

# The memory monitor listener puts a message on the Execution, and the next checkCancelOrTimeout
# throws MemoryLimitExceededException with that message. A consumer of the gem shows this message to
# an end user, so the message must hold no connect string. The connect string holds the JDBC user,
# and it holds the whole schema XML when the caller passes the schema inline.
describe "Memory monitor message" do
  before do
    create_olap_connection
  end

  # MemoryMonitorFactory keeps one monitor per JVM, in the singleInstance field of
  # ObjectFactory.Singleton. MemoryMonitorFactory.setThreadLocalClassName does not work here, because
  # RolapResultShepherd#shepherdExecution runs the query on a thread of its own executor.
  def with_memory_monitor(monitor)
    factory_field = Java::MondrianUtil::MemoryMonitorFactory.java_class.declared_field('factory')
    factory_field.accessible = true
    factory = factory_field.value(nil)
    instance_field = Java::MondrianUtil::ObjectFactory::Singleton.java_class.declared_field('singleInstance')
    instance_field.accessible = true
    previous_monitor = instance_field.value(factory)
    instance_field.set(factory, monitor)
    begin
      yield
    ensure
      instance_field.set(factory, previous_monitor)
    end
  end

  def memory_limit_error
    with_memory_monitor(ImmediateMemoryMonitor.new) do
      assert_raises Mondrian::OLAP::Error do
        @olap.execute("SELECT [Measures].[Unit Sales] ON COLUMNS FROM [Sales]")
      end
    end
  end

  it "reports the used and the maximum memory and nothing else" do
    expected = "OutOfMemory used=#{ImmediateMemoryMonitor::USED_MEMORY}, " \
      "max=#{ImmediateMemoryMonitor::MAX_MEMORY}"

    assert_equal expected, memory_limit_error.root_cause_message
  end

  # A caller detects the condition with the OutOfMemory word, and it reads the root cause and not the
  # message of the wrapper exception.
  it "raises MemoryLimitExceededException as the root cause" do
    error = memory_limit_error

    assert_kind_of Java::MondrianOlap::MemoryLimitExceededException, error.root_cause
    assert error.root_cause_message.start_with?('OutOfMemory'),
      "expected the message to start with OutOfMemory, got #{error.root_cause_message.inspect}"
  end
end
