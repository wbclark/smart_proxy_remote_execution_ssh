require 'base64'

module Proxy::RemoteExecution::Ssh::Runners
  class PollingScriptRunner < ScriptRunner
    DEFAULT_REFRESH_INTERVAL = 60

    def self.load_script(name)
      script_dir = File.expand_path('../async_scripts', __dir__)
      File.read(File.join(script_dir, name))
    end

    # The script that controls the flow of the job, able to initiate update or
    # finish on the task, or take over the control over script lifecycle
    CONTROL_SCRIPT = load_script('control.sh')

    # The script always outputs at least one line
    # First line of the output either has to begin with
    # "RUNNING" or "DONE $EXITCODE"
    # The following lines are treated as regular output
    RETRIEVE_SCRIPT = load_script('retrieve.sh')

    def initialize(options, user_method, suspended_action: nil)
      super(options, user_method, suspended_action: suspended_action)
      @callback_host = options[:callback_host]
      @task_id = options[:uuid]
      @step_id = options[:step_id]
      @otp = Proxy::Dynflow::OtpManager.generate_otp(@task_id)
    end

    def prepare_start
      super
      @base_dir = File.dirname @remote_script
      upload_control_scripts
    end

    def initialization_script
      close_stdin = '</dev/null'
      close_fds = close_stdin + ' >/dev/null 2>/dev/null'
      main_script = "(#{@remote_script_wrapper} #{@remote_script} #{close_stdin} 2>&1; echo $?>#{@base_dir}/init_exit_code) >#{@base_dir}/output"
      control_script_finish = "#{@control_script_path} init-script-finish"
      <<-SCRIPT.gsub(/^ +\| /, '')
      | export CONTROL_SCRIPT="#{@control_script_path}"
      | #{"chown #{@user_method.effective_user} #{@base_dir}" if @user_method.cli_command_prefix}
      | #{@user_method.cli_command_prefix} sh -c '#{main_script}; #{control_script_finish}' #{close_fds} &
      SCRIPT
    end

    def trigger(*args)
      run_sync(*args)
    end

    def refresh
      begin
        pm = run_sync("#{@user_method.cli_command_prefix} #{@retrieval_script}")
      rescue StandardError => e
        @logger.info("Error while connecting to the remote host on refresh: #{e.message}")
      end

      process_retrieved_data(pm.stdout.to_s.chomp, pm.stderr.to_s.chomp)
    ensure
      destroy_session
    end

    def kill
      run_sync("pkill -P $(cat #{@pid_path})")
    rescue StandardError => e
      publish_exception('Unexpected error', e, false)
    end

    def process_retrieved_data(output, err)
      return if output.nil? || output.empty?

      lines = output.lines
      result = lines.shift.match(/^DONE (\d+)?/)
      publish_data(lines.join, 'stdout') unless lines.empty?
      publish_data(err, 'stderr') unless err.empty?
      if result
        exitcode = result[1] || 0
        publish_exit_status(exitcode.to_i)
        cleanup
      end
    end

    def external_event(event)
      data = event.data
      if data['manual_mode']
        load_event_updates(data)
      else
        # getting the update from automatic mode - reaching to the host to get the latest update
        return run_refresh
      end
    ensure
      destroy_session
    end

    def close
      super
      Proxy::Dynflow::OtpManager.drop_otp(@task_id, @otp) if @otp
    end

    def upload_control_scripts
      return if @control_scripts_uploaded

      cp_script_to_remote(env_script, 'env.sh')
      @control_script_path = cp_script_to_remote(CONTROL_SCRIPT, 'control.sh')
      @retrieval_script = cp_script_to_remote(RETRIEVE_SCRIPT, 'retrieve.sh')
      @control_scripts_uploaded = true
    end

    # Script setting the dynamic values to env variables: it's sourced from other control scripts
    def env_script
      <<-SCRIPT.gsub(/^ +\| /, '')
      | CALLBACK_HOST="#{@callback_host}"
      | TASK_ID="#{@task_id}"
      | STEP_ID="#{@step_id}"
      | OTP="#{@otp}"
      SCRIPT
    end

    private

    # Generates updates based on the callback data from the manual mode
    def load_event_updates(event_data)
      continuous_output = Proxy::Dynflow::ContinuousOutput.new
      if event_data.key?('output')
        lines = Base64.decode64(event_data['output']).sub(/\A(RUNNING|DONE).*\n/, '')
        continuous_output.add_output(lines, 'stdout')
      end
      cleanup if event_data['exit_code']
      new_update(continuous_output, event_data['exit_code'])
    end

    def cleanup
      if @cleanup_working_dirs
        ensure_remote_command("rm -rf #{remote_command_dir}",
                              publish: true,
                              error: "Unable to remove working directory #{remote_command_dir} on remote system, exit code: %{exit_code}")
      end
    end

    def destroy_session
      if @session
        @logger.debug("Closing session with #{@ssh_user}@#{@host}")
        close_session
      end
    end
  end
end
