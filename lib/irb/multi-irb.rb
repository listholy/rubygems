#
#   multi-irb.rb - multiple irb module
#   	$Release Version: 0.6$
#   	$Revision$
#   	$Date$
#   	by Keiju ISHITSUKA(Nippon Rational Inc.)
#
# --
#
#   
#
IRB.fail CanNotGoMultiIrbMode unless defined?(Thread)
require "thread"

module IRB
  # job management class
  class JobManager
    @RCS_ID='-$Id$-'

    def initialize
      # @jobs = [[thread, irb],...]
      @jobs = []
      @current_job = nil
    end

    attr :current_job, true

    def n_jobs
      @jobs.size
    end

    def thread(key)
      th, irb = search(key)
      irb
    end

    def irb(key)
      th, irb = search(key)
      irb
    end

    def main_thread
      @jobs[0][0]
    end

    def main_irb
      @jobs[0][1]
    end

    def insert(irb)
      @jobs.push [Thread.current, irb]
    end

    def switch(key)
      th, irb = search(key)
      IRB.fail IrbAlreadyDead unless th.alive?
      IRB.fail IrbSwitchToCurrentThread if th == Thread.current
      @current_job = irb
      th.run
      Thread.stop
      @current_job = irb(Thread.current)
    end

    def kill(*keys)
      for key in keys
	th, irb = search(key)
	IRB.fail IrbAlreadyDead unless th.alive?
	th.exit
      end
    end    

    def search(key)
      case key
      when Integer
	@jobs[key]
      when Irb
	@jobs.find{|k, v| v.equal?(irb)}
      when Thread
	@jobs.assoc(key)
      else
	assoc = @jobs.find{|k, v| v.context.main.equal?(key)}
	IRB.fail NoSuchJob, key if assoc.nil?
	assoc
      end
    end

    def delete(key)
      case key
      when Integer
	IRB.fail NoSuchJob, key unless @jobs[key]
	@jobs[key] = nil
      else
	catch (:EXISTS) do
	  @jobs.each_index do
	    |i|
	    if @jobs[i] and (@jobs[i][0] == key ||
			     @jobs[i][1] == key ||
			     @jobs[i][1].context.main.equal?(key))
	      @jobs[i] = nil
	      throw :EXISTS
	    end
	  end
	  IRB.fail NoSuchJob, key
	end
      end
      until assoc = @jobs.pop; end unless @jobs.empty?
      @jobs.push assoc
    end

    def inspect
      ary = []
      @jobs.each_index do
	|i|
	th, irb = @jobs[i]
	next if th.nil?

	if th.alive?
	  if th.stop?
	    t_status = "stop"
	  else
	    t_status = "running"
	  end
	else
	  t_status = "exited"
	end
	ary.push format("#%d->%s on %s (%s: %s)",
			i, 
			irb.context.irb_name, 
			irb.context.main,
			th,
			t_status)
      end
      ary.join("\n")
    end
  end

  @JobManager = JobManager.new

  def IRB.JobManager
    @JobManager
  end

  # invoke multiple irb 
  def IRB.irb(file = nil, *main)
    workspace = IRB.workspace_binding(*main)
    if main.empty?
      main = eval("self", workspace)
    else
      main = main[0]
    end
    parent_thread = Thread.current
    Thread.start do
      begin
	irb = Irb.new(main, workspace, file)
      rescue 
	print "Subirb can't start with context(self): ", main.inspect, "\n"
	print "return to main irb\n"
	Thread.pass
	Thread.main.wakeup
	Thread.exit
      end
      @CONF[:IRB_RC].call(irb.context) if @CONF[:IRB_RC]
      @JobManager.insert(irb)
      begin
	system_exit = false
	catch(:IRB_EXIT) do
	  irb.eval_input
	end
      rescue SystemExit
	system_exit = true
	raise
	#fail
      ensure
	unless system_exit
	  @JobManager.delete(irb)
	  if parent_thread.alive?
	    @JobManager.current_job = @JobManager.irb(parent_thread)
	    parent_thread.run
	  else
	    @JobManager.current_job = @JobManager.main_irb
	    @JobManager.main_thread.run
	  end
	end
      end
    end
    Thread.stop
    @JobManager.current_job = @JobManager.irb(Thread.current)
  end

  class Context
    def _=(value)
      @_ = value
      eval "_ = IRB.JobManager.irb(Thread.current).context._", @bind
    end
  end

  module ExtendCommand
    def irb_context
      IRB.JobManager.irb(Thread.current).context
    end
    alias conf irb_context
  end

  @CONF[:SINGLE_IRB_MODE] = false
  @JobManager.insert(@CONF[:MAIN_CONTEXT].irb)
  @JobManager.current_job = @CONF[:MAIN_CONTEXT].irb

  trap("SIGINT") do
    @JobManager.current_job.signal_handle
  end

end
