#
# Copyright 2014-2016, Noah Kantrowitz
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'base64'

require 'kitchen/transport/ssh'
require 'net/ssh'

require 'kitchen-sync/core_ext'

module Kitchen
  module Transport
    class Rsync < Ssh
      def finalize_config!(instance)
        super.tap do
          if defined?(Kitchen::Verifier::Inspec) && instance.verifier.is_a?(Kitchen::Verifier::Inspec)
            instance.verifier.send(:define_singleton_method, :runner_options_for_rsync) do |config_data|
              runner_options_for_ssh(config_data)
            end
          end
        end
      end

      # Copy-pasta from Ssh#create_new_connection because I need the Rsync
      # connection class.
      # Tracked in https://github.com/test-kitchen/test-kitchen/pull/726
      def create_new_connection(options, &block)
        if @connection
          logger.debug("[rsync] shutting previous connection #{@connection}")
          @connection.close
        end

        @connection_options = options
        @connection = self.class::Connection.new(config, options, &block)
      end

      class Connection < Ssh::Connection
        def initialize(config, options, &block)
          @config = config
          super(options, &block)
        end

        def upload(locals, remote)
          if @rsync_failed || !File.exists?('/usr/bin/rsync')
            logger.debug('[rsync] Rsync already failed or not installed, not trying it')
            return super
          end

          locals = Array(locals)

          # We only try to sync folders for now and ignore the cache folder
          # because we don't want to --delete that.
          rsync_candidates = locals.select {|path| File.directory?(path) && File.basename(path) != 'cache' }

          ssh_command = "ssh #{ssh_args.join(' ')}"

          rsync_cmd = "/usr/bin/rsync -e '#{ssh_command}' -az#{logger.level == :debug ? 'vv' : ''} --no-o --no-g --delete #{rsync_candidates.join(' ')} #{@session.options[:user]}@#{@session.host}:#{remote}"
          logger.debug("[rsync] Running rsync command: #{rsync_cmd}")
          ret = []
          time = Benchmark.realtime do
            ret << system(rsync_cmd)
          end
          logger.info("[rsync] Time taken to upload #{rsync_candidates.join(';')} to #{self}:#{remote}: %.2f sec" % time)
          unless ret.first
            logger.warn("[rsync] rsync exited with status #{$?.exitstatus}, using SCP instead")
            @rsync_failed = true
          end

          # Fall back to SCP
          remaining = if @rsync_failed
            locals
          else
            locals - rsync_candidates
          end
          logger.debug("[rsync] Using fallback to upload #{remaining.join(';')}")
          super(remaining, remote) unless remaining.empty?
        end

        def ssh_args
          args = %W{ -o UserKnownHostsFile=/dev/null }
          args += %W{ -o StrictHostKeyChecking=no }
          args += %W{ -o UserKnownHostsFile=/dev/null }
          args += %W{ -o IdentitiesOnly=yes } if @config[:ssh_key]
          args += %W{ -o LogLevel=#{@logger.debug? ? "VERBOSE" : "ERROR"} }
          args += %W{ -o ForwardAgent=#{@config[:forward_agent] ? "yes" : "no"} } if @config.key? :forward_agent
          args += %W{ -i #{@config[:ssh_key]} } if @config[:ssh_key]
          args += %W{ -p #{@session.options[:port]}}
        end
      end

    end
  end
end
