# Encoding: Utf-8
module Bouncefetch
  class Application
    module Dispatch
      def dispatch action = (@opts[:dispatch] || :help)
        case action
          when :version, :info then dispatch_info
          else
            if respond_to?("dispatch_#{action}")
              send("dispatch_#{action}")
            else
              abort("unknown action #{action}", 1)
            end
        end
      end

      def graceful opts = {}, &block
        begin
          opts = { expunge: true, registry: true }.merge(opts)
          block.try(:call)
        ensure
          # graceful shutdown
          begin
            unless @opts[:simulate]
              log_perform_failsafe("Performing IMAP expunge...") { connection.expunge } if opts[:expunge] && connected?
              log_perform_failsafe("Saving registry...") { @registry.save } if opts[:registry] && @registry
            end
          rescue ; end
          begin ; connection.logout if connected? ; rescue ; end
          begin ; connection.disconnect if connected? ; rescue ; end
        end
      end

      def dispatch_help_short
        logger.log_without_timestr do
          @optparse.to_s.split("\n").each(&method(:log))
        end
      end

      def dispatch_upgrade
        log c("You're running #{Bouncefetch::VERSION}", :blue)

        # git pull
        log "Pull latest changes..."
        system %{cd "#{Bouncefetch::ROOT}" && git pull}

        # bundle
        log "Installing bundle..."
        system %{cd "#{Bouncefetch::ROOT}" && bundle install}

        log c("You're now running #{File.read("#{Bouncefetch::ROOT}/VERSION")}", :blue)
      end

      def dispatch_help
        logger.log_without_timestr do
          @optparse.to_s.split("\n").each(&method(:log))
          log ""
          log "Config directory: " << c("#{ROOT}/config", :magenta)
          log ""
          log "Legend:"
          log "  " << c("X  ", :green) << c("handled mails")
          log "  " << c("X  ", :red) << c("handled but client not identifyable")
          log "  " << c(".  ", :yellow) << c("ignored")
          log "  " << c("%  ", :red) << c("deleted (follows ") << c("X", :green) << c(" or ") << c(".", :yellow) << c(")")
          log "  " << c("?  ", :blue) << c("unmatched")
          log "  " << c("§  ", :blue) << c("no matching crosscheck")
          log "  " << c("E  ", :magenta) << c("performing IMAP expunge (delete marked mails)")
        end
      end

      def dispatch_info
        logger.log_without_timestr do
          log ""
          log "     Your version: #{your_version = Gem::Version.new(Bouncefetch::VERSION)}"

          # get current version
          logger.log_with_print do
            log "  Current version: "
            if @opts[:check_for_updates]
              log c("checking...", :blue)

              begin
                current_version = Gem::Version.new Net::HTTP.get_response(URI.parse(Bouncefetch::UPDATE_URL)).body.strip

                if current_version > your_version
                  status = c("#{current_version} (consider update)", :red)
                elsif current_version < your_version
                  status = c("#{current_version} (ahead, beta)", :green)
                else
                  status = c("#{current_version} (up2date)", :green)
                end
              rescue
                status = c("failed (#{$!.message})", :red)
              end

              logger.raw "#{"\b" * 11}#{" " * 11}#{"\b" * 11}", :print # reset cursor
              log status
            else
              log c("check disabled", :red)
            end
          end

          # more info
          log ""
          log "  Bouncefetch is brought to you by #{c "bmonkeys.net", :green}"
          log "  Contribute @ #{c "github.com/2called-chaos/bouncefetch", :cyan}"
          log "  Eat bananas every day!"
          log ""
        end
      end

      def dispatch_statistics
        load_configuration!
        load_registry!

        log_perform_failsafe("Loading statistics") { @registry_stats = @registry.stats }
        longest_key = @registry_stats.keys.map{|s| s.to_s.length }.max

        log ""
        @registry_stats.each do |key, val|
          val1, val2 = val
          log c("#{key}: ".rjust(longest_key + 2, " "), :blue) << [c("#{val1}", val2 ? :magenta : :yellow), c("#{val2}", :yellow)].join(" ")
        end
        log ""
      end

      def dispatch_list_candidates
        load_configuration!
        load_registry!

        graceful expunge: false, registry: false do
          items = registry.reached_limit
          if items.any?
            log "Found " << c("#{items.count}", :magenta) << c(" candidates.")
            logger.log_without_timestr do
              candidates_to_array(items, opts[:export_columns]).each_with_index do |row, i|
                if i == 0
                  logger.raw row.map{|r| c(r, :blue) }.join(c("|", :red))
                else
                  logger.raw row.join(c("|", :red))
                end
              end
            end
          else
            log "No candidates found."
          end
        end
      end

      def dispatch_export
        load_configuration!
        load_registry!

        graceful expunge: false do
          result_file = File.expand_path(opts[:remote])
          items = registry.reached_limit
          log "Found " << c("#{items.count}", :magenta) << c(" candidates.")

          csv = log_perform_failsafe("Generating CSV") { candidates_to_csv(items, opts[:export_columns]) }

          # check if file exists
          if FileTest.exists?(result_file)
            warn "Target file already exists!"
            q = ask "Overwrite file? [yn]" until "#{q}".downcase.start_with?("y", "n")
            exit 1 if q.downcase.start_with?("n")
          end

          # write to file
          write_succeeded = false
          log_perform_failsafe("Writing CSV to file") do
            File.open(result_file, "wb") {|file| file.write(csv) }
            write_succeeded = true
          end
          if !opts[:simulate] && write_succeeded
            log_perform_failsafe("Removing candidates from registry") do
              items.each {|candidate, _| registry.remove(candidate) }
            end
          end
        end
      end

      def dispatch_export_remote
        load_configuration!
        load_registry!

        graceful expunge: false do
          items = registry.reached_limit
          log "Found " << c("#{items.count}", :magenta) << c(" candidates.")

          # Post to remote
          post_succeeded = false
          log_perform_failsafe("POSTing data to remote endpoint...") do
            res = Net::HTTP.post_form URI(opts[:remote]), { "candidates" => candidates_to_json(items, opts[:export_columns]) }
            raise "server responded with status code #{res.code}" if res.code.to_i != 200
            post_succeeded = true
          end

          if !opts[:simulate] && post_succeeded
            log_perform_failsafe("Removing candidates from registry") do
              items.each {|candidate, _| registry.remove(candidate) }
            end
          end
        end
      end

      def dispatch_mailboxes
        load_configuration!

        graceful expunge: false do
          connection # connect and authorize imap
          connection.list('', '*').each{|m| log c("#{m.name}", :magenta) }
        end
      end

      def dispatch_shell
        load_configuration!
        load_registry!

        graceful do
          connection # connect and authorize imap
          log "Type " << c("exit", :magenta) << c(" to gracefully end the session.")
          log "Type " << c("exit!", :magenta) << c(" to terminate session (escape loop).") << c(" WARNING: No graceful shutdown!", :red)
          log "Type " << c("graceful_exit!", :magenta) << c(" to gracefully terminate session (escape loop).")
          log "You have the following local variables: " << c("connection, config, registry, opts", :magenta)
          log "You can save the registry with " << c("registry.save", :magenta) << c(" and reload it with ") << c("registry.load!", :magenta)
          binding.pry(quiet: true)
        end
      end

      def dispatch_index
        load_configuration!
        load_registry!
        enable_signal_trapping!

        graceful do
          mailboxes = cfg("imap.mailboxes")
          connection # eager imap connect and authorize

          begin
            mailboxes.each_with_index do |mailbox, i|
              selected = false
              # select mailbox
              logger.log_with_print do
                log "Selecting #{i+1}/#{mailboxes.count} " << c("#{mailbox}", :magenta) << c("... ")
                begin
                  connection.select(mailbox)
                  logger.raw c("OK", :green)
                  selected = true
                rescue Net::IMAP::NoResponseError
                  logger.raw c("FAILED (#{$!.message.strip})", :red)
                end
              end

              if selected
                logger.log_with_print do
                  logger.log_without_timestr do
                    # search emails
                    imap_search_headers.each do |query|
                      imap_search(query) do |mail|
                        may_pause
                        may_exit
                        mid_expunge
                        handle_throttle
                        handle_mail(mail)
                      end
                    end

                    # expunge before selecting another mailbox
                    if !@opts[:simulate] && connected?
                      log(c("E", :yellow))
                      connection.expunge
                      logger.raw "\b \b#{c("E", :magenta)}"
                    end
                  end
                end
              end
            end

            log c("All finished!", :green)
          ensure
            log ""
            @stats.render.each {|l| log(l) }
          end
        end
      end
    end
  end
end
