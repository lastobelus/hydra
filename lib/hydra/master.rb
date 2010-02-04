require 'hydra/hash'
module Hydra #:nodoc:
  # Hydra class responsible for delegate work down to workers.
  #
  # The Master is run once for any given testing session.
  class Master
    include Hydra::Messages::Master
    # Create a new Master
    #
    # Options:
    # * :files
    #   * An array of test files to be run. These should be relative paths from
    #     the root of the project, since they may be run on different machines
    #     which may have different paths.
    # * :workers
    #   * An array of hashes. Each hash should be the configuration options
    #     for a worker.
    def initialize(opts = { })
      opts.stringify_keys!
      config_file = opts.delete('config') { nil }
      if config_file
        opts.merge!(YAML.load_file(config_file).stringify_keys!)
      end
      @files = opts.fetch('files') { [] }
      @incomplete_files = @files.dup
      @workers = []
      @listeners = []
      @verbose = opts.fetch('verbose') { false }
      # default is one worker that is configured to use a pipe with one runner
      worker_cfg = opts.fetch('workers') { [ { 'type' => 'local', 'runners' => 1} ] }

      $stdout.write "MASTER| Initialized\n" if @verbose
      $stdout.write "MASTER|   Files:   (#{@files.inspect})\n" if @verbose
      $stdout.write "MASTER|   Workers: (#{worker_cfg.inspect})\n" if @verbose
      $stdout.write "MASTER|   Verbose: (#{@verbose.inspect})\n" if @verbose

      boot_workers worker_cfg
      process_messages
    end

    # Message handling
    
    # Send a file down to a worker. If there are no more files, this will shut the
    # worker down.
    def send_file(worker)
      f = @files.pop
      worker[:io].write(RunFile.new(:file => f)) if f
    end

    # Process the results coming back from the worker.
    def process_results(worker, message)
      $stdout.write message.output
      # only delete one
      @incomplete_files.delete_at(@incomplete_files.index(message.file))
      $stdout.write "MASTER| #{@incomplete_files.size} Files Remaining\n" if @verbose
      if @incomplete_files.empty?
        shutdown_all_workers
      else
        send_file(worker)
      end
    end

    private
    
    def boot_workers(workers)
      $stdout.write "MASTER| Booting #{workers.size} workers\n" if @verbose
      workers.each do |worker|
        worker.stringify_keys!
        $stdout.write "MASTER| worker opts #{worker.inspect}\n" if @verbose
        type = worker.fetch('type') { 'local' }
        if type.to_s == 'local'
          boot_local_worker(worker)
        elsif type.to_s == 'ssh'
          @workers << worker # will boot later, during the listening phase
        else
          raise "Worker type not recognized: (#{type.to_s})"
        end
      end
    end

    def boot_local_worker(worker)
      runners = worker.fetch('runners') { raise "You must specify the number of runners" }
      $stdout.write "MASTER| Booting local worker\n" if @verbose 
      pipe = Hydra::Pipe.new
      child = Process.fork do
        pipe.identify_as_child
        Hydra::Worker.new(:io => pipe, :runners => runners, :verbose => @verbose)
      end
      pipe.identify_as_parent
      @workers << { :pid => child, :io => pipe, :idle => false, :type => :local }
    end

    def boot_ssh_worker(worker)
      runners = worker.fetch('runners') { raise "You must specify the number of runners"  }
      connect = worker.fetch('connect') { raise "You must specify SSH connection options" }
      directory = worker.fetch('directory') { raise "You must specify a remote directory" }
      command = worker.fetch('command') { 
        "ruby -e \"require 'rubygems'; require 'hydra'; Hydra::Worker.new(:io => Hydra::Stdio.new, :runners => #{runners}, :verbose => #{@verbose});\""
      }

      $stdout.write "MASTER| Booting SSH worker\n" if @verbose 
      ssh = Hydra::SSH.new(connect, directory, command)
      return { :io => ssh, :idle => false, :type => :ssh }
    end

    def shutdown_all_workers
      $stdout.write "MASTER| Shutting down all workers\n" if @verbose
      @workers.each do |worker|
        worker[:io].write(Shutdown.new) if worker[:io]
        worker[:io].close if worker[:io] 
      end
      @listeners.each{|t| t.exit}
    end

    def process_messages
      Thread.abort_on_exception = true

      $stdout.write "MASTER| Processing Messages\n" if @verbose
      $stdout.write "MASTER| Workers: #{@workers.inspect}\n" if @verbose
      @workers.each do |worker|
        @listeners << Thread.new do
          $stdout.write "MASTER| Listening to #{worker.inspect}\n" if @verbose
           if worker.fetch('type') { 'local' }.to_s == 'ssh'
             worker = boot_ssh_worker(worker)
             @workers << worker
           end
          while true
            begin
              message = worker[:io].gets
              $stdout.write "MASTER| got message: #{message}\n" if @verbose
              message.handle(self, worker) if message
            rescue IOError
              $stderr.write "MASTER| lost Worker [#{worker.inspect}]\n" if @verbose
              Thread.exit
            end
          end
        end
      end
      
      @listeners.each{|l| l.join}
    end
  end
end
