##############################################################################
# Etch configuration file management tool library
##############################################################################

require 'facter'
require 'find'
require 'digest/sha1' # hexdigest
require 'base64'      # decode64, encode64
require 'net/http'
require 'net/https'
require 'rexml/document'
require 'fileutils'   # copy, mkpath, rmtree
require 'fcntl'       # Fcntl::O_*
require 'etc'         # getpwnam, getgrname
require 'tempfile'    # Tempfile

# clean up "using default DH parameters" warning for https
# http://blog.zenspider.com/2008/05/httpsssl-warning-cleanup.html
class Net::HTTP
  alias :old_use_ssl= :use_ssl=
  def use_ssl= flag
    self.old_use_ssl = flag
    @ssl_context.tmp_dh_callback = proc {}
  end
end

module Etch
end

class Etch::Client
  CONFIRM_PROCEED = 1
  CONFIRM_SKIP = 2
  CONFIRM_QUIT = 3

  attr_reader :exec_once_per_run

  # Cutting down the size of the arg list would be nice
  def initialize(server=nil, tag=nil, varbase=nil, debug=false, dryrun=false, interactive=false, filenameonly=false, fullfile=false)
    @server = server.nil? ? 'https://etch' : server
    @tag = tag
    @varbase = varbase.nil? ? '/var/etch' : varbase
    @debug = debug
    @dryrun = dryrun
    @interactive = interactive
    @filenameonly = filenameonly
    @fullfile = fullfile
    
    # Ensure we have a sane path, particularly since we are often run from
    # cron.
    # FIXME: Read from config file
    ENV['PATH'] = '/bin:/usr/bin:/sbin:/usr/sbin:/opt/csw/bin:/opt/csw/sbin'

    @origbase    = File.join(@varbase, 'orig')
    @historybase = File.join(@varbase, 'history')
    @lockbase    = File.join(@varbase, 'locks')
    
    @blankrequest = {}
    facts = Facter.to_hash
    facts.each_pair { |key, value| @blankrequest["facts[#{key}]"] = value.to_s }
    if @debug
      @blankrequest['debug'] = '1'
    end
    if @tag
      @blankrequest['tag'] = @tag
    end

    @locked_files = {}
    @first_update = {}
    @already_processed = {}
    @exec_already_processed = {}
    @exec_once_per_run = {}
  end
  
  def process_until_done(files_to_generate, lockforce)
    check_for_disable_etch_file
    remove_stale_lock_files(lockforce)

    # Assemble the initial request
    request = get_blank_request

    if !files_to_generate.nil? && !files_to_generate.empty?
      files_to_generate.each do |file|
        request["files[#{CGI.escape(file)}][sha1sum]"] = get_orig_sum(file)
      end
    else
      request['files[GENERATEALL]'] = '1'
    end

    #
    # Loop back and forth with the server sending requests for files and
    # responding to the server's requests for original contents or sums
    # it needs
    #

    Signal.trap('EXIT') { unlock_all_files }

    uri = URI.parse(@server + '/files')
    http = Net::HTTP.new(uri.host, uri.port)
    if uri.scheme == "https"
      http.use_ssl = true
      if File.exist?('/etc/etch/ca.pem')
        http.ca_file = '/etc/etch/ca.pem'
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      elsif File.directory?('/etc/etch/ca')
        http.ca_path = '/etc/etch/ca'
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      end
    end
    http.start

    10.times do
      #
      # Send request to server
      #

      puts "Sending request to server #{uri}" if (@debug)
      post = Net::HTTP::Post.new(uri.path)
      post.set_form_data(request)
      response = http.request(post)
      response_xml = nil
      case response
      when Net::HTTPSuccess
        puts "Response from server:\n'#{response.body}'" if (@debug)
        if !response.body.nil? && !response.body.empty?
            response_xml = REXML::Document.new(response.body)
        else
          puts "  Response is empty" if (@debug)
          break
        end
      else
        response.error!
        puts response.body
        abort
      end

      #
      # Process the response from the server
      #

      # Prep a clean request hash
      request = get_blank_request

      # With generateall we expect to make at least two round trips to the server.
      # 1) Send GENERATEALL request, get back a list of need_sums
      # 2) Send sums, possibly get back some need_origs
      # 3) Send origs, get back generated files
      need_to_loop = false
      reset_already_processed
      # Process configs first, as they may contain setup entries that are
      # needed to create the original files.
      response_xml.root.elements.each('/files/configs/config') do |config|
        puts "Processing config for #{config.attributes['filename']}" if (@debug)
        process(response_xml, config.attributes['filename'])
      end
      response_xml.root.elements.each('/files/need_sums/need_sum') do |need_sum|
        puts "Processing request for sum of #{need_sum.text}" if (@debug)
        request["files[#{CGI.escape(need_sum.text)}][sha1sum]"] = get_orig_sum(need_sum.text)
        need_to_loop = true
      end
      response_xml.root.elements.each('/files/need_origs/need_orig') do |need_orig|
        puts "Processing request for contents of #{need_orig.text}" if (@debug)
        request["files[#{CGI.escape(need_orig.text)}][contents]"] = Base64.encode64(get_orig_contents(need_orig.text))
        request["files[#{CGI.escape(need_orig.text)}][sha1sum]"] = get_orig_sum(need_orig.text)
        need_to_loop = true
      end

      if !need_to_loop
        break
      end
    end

    puts "Processing 'exec once per run' commands" if (!exec_once_per_run.empty?)
    exec_once_per_run.keys.each do |exec|
      process_exec('post', exec)
    end
    
    # Send results to server
    # FIXME
  end

  def check_for_disable_etch_file
    disable_etch = File.join(@varbase, 'disable_etch')
    if File.exist?(disable_etch)
      puts "Etch disabled:"
      $stdout.write(IO.read(disable_etch))
      exit(200)
    end
  end
  
  def get_blank_request
    @blankrequest.dup
  end
  
  def process(response_xml, file)
    puts "Processing #{file}" if (@debug)

    # Skip files we've already processed in response to <depend>
    # statements.
    if @already_processed.has_key?(file)
      puts "Skipping already processed #{file}" if (@debug)
      return
    end

    # The %locked_files hash provides a convenient way to
    # detect circular dependancies.  It doesn't give us an ordered
    # list of dependancies, which might be handy to help the user
    # debug the problem, but I don't think it's worth maintaining a
    # seperate array just for that purpose.
    if @locked_files.has_key?(file)
      abort "Circular dependancy detected.  " +
        "Dependancy list (unsorted) contains:\n  " +
        @locked_files.keys.join(', ')
    end

    lock_file(file)
    done = false

    # We have to make a new document so that XPath paths are referenced
    # relative to the configuration for this specific file.
    config = REXML::Document.new(response_xml.root.elements["/files/configs/config[@filename='#{file}']"].to_s)

    # Process any other files that this file depends on
    config.elements.each('/config/depend') do |depend|
      puts "Generating dependency #{depend.text}" if (@debug)
      process(response_xml, depend.text)
    end

    # See what type of action the user has requested

    # Check to see if the user has requested that we revert back to the
    # original file.
    if config.elements['/config/revert']
      origpathbase = File.join(@origbase, file)

      # Restore the original file if it is around
      if File.exist?("#{origpathbase}.ORIG")
        origpath = "#{origpathbase}.ORIG"
        origdir = File.dirname(origpath)
        origbase = File.basename(origpath)
        filedir = File.dirname(file)

        # Remove anything we might have written out for this file
        remove_file(file) if (!@dryrun)

        puts "Restoring #{origpath} to #{file}"
        recursive_copy_and_rename(origdir, origbase, file) if (!@dryrun)

        # Now remove the backed-up original so that future runs
        # don't do anything
        remove_file(origpath) if (!@dryrun)
      elsif File.exist?("#{origpathbase}.TAR")
        origpath = "#{origpathbase}.TAR"
        filedir = File.dirname(file)

        # Remove anything we might have written out for this file
        remove_file(file) if (!@dryrun)

        puts "Restoring #{file} from #{origpath}"
        system("cd #{filedir} && tar xf #{origpath}") if (!@dryrun)

        # Now remove the backed-up original so that future runs
        # don't do anything
        remove_file(origpath) if (!@dryrun)
      elsif File.exist?("#{origpathbase}.NOORIG")
        origpath = "#{origpathbase}.NOORIG"
        puts "Original #{file} didn't exist, restoring that state"

        # Remove anything we might have written out for this file
        remove_file(file) if (!@dryrun)

        # Now remove the backed-up original so that future runs
        # don't do anything
        remove_file(origpath) if (!@dryrun)
      end

      done = true
    end

    if config.elements['/config/file'] && !done  # Regular file
      # Perform any setup commands that the user has requested.
      # These are occasionally needed to install software that is
      # required to generate the file (think m4 for sendmail.cf) or to
      # install a package containing a sample config file which we
      # then edit with a script, and thus doing the install in <pre>
      # is too late.
      if config.elements['/config/setup']
        process_setup(file, config)
      end

      newcontents = nil
      if config.elements['/config/file/contents']
        newcontents = Base64.decode64(config.elements['/config/file/contents'].text)
      end

      permstring = config.elements['/config/file/perms'].text
      perms = permstring.oct
      owner = config.elements['/config/file/owner'].text
      group = config.elements['/config/file/group'].text
      uid = lookup_uid(owner)
      gid = lookup_gid(group)

      compare_file_contents = false
      if newcontents
        compare_file_contents = compare_file_contents(file, newcontents)
      end
      compare_permissions = compare_permissions(file, perms)
      compare_ownership = compare_ownership(file, uid, gid)

      # Proceed if:
      # - The new contents are different from the current file
      # - The permissions or ownership requested don't match the
      #   current permissions or ownership
      if !compare_file_contents &&
         !compare_permissions &&
         !compare_ownership
        puts "No change to #{file} necessary" if (@debug)
        done = true
      else
        # Tell the user what we're going to do
        if compare_file_contents
          # If the new contents are different from the current file
          # show that to the user in the format they've requested.
          # If the requested permissions are not world-readable then
          # use the filenameonly format so that we don't disclose
          # non-public data.
          if @filenameonly || permstring.to_i(8) & 0004 == 0
            puts "Will write out new #{file}"
          elsif @fullfile
            # Grab the first 8k of the contents
            first8k = newcontents.slice(0, 8192)
            # Then check it for null characters.  If it has any it's
            # likely a binary file.
            hasnulls = true if (first8k =~ /\0/)

            if !hasnulls
              puts "Generated contents for #{file}:"
              puts "============================================="
              puts newcontents
              puts "============================================="
            else
              puts "Will write out new #{file}, but " +
                   "generated contents are not plain text so " +
                   "they will not be displayed"
            end
          else
            # Default is to show a diff of the current file and the
            # newly generated file.
            puts "Will make the following changes to #{file}, diff -c:"
            tempfile = Tempfile.new(File.basename(file))
            tempfile.write(newcontents)
            tempfile.close
            puts "============================================="
            if File.file?(file) && !File.symlink?(file)
              system("diff -c #{file} #{tempfile.path}")
            else
              # Either the file doesn't currently exist,
              # or is something other than a normal file
              # that we'll be replacing with a file.  In
              # either case diffing against /dev/null will
              # produce the most logical output.
              system("diff -c /dev/null #{tempfile.path}")
            end
            puts "============================================="
            tempfile.delete
          end
        end
        if compare_permissions
          puts "Will set permissions on #{file} to #{permstring}"
        end
        if compare_ownership
          puts "Will set ownership of #{file} to #{uid}:#{gid}"
        end

        # If the user requested interactive mode ask them for
        # confirmation to proceed.
        if @interactive
          case get_user_confirmation()
          when CONFIRM_PROCEED
            # No need to do anything
          when CONFIRM_SKIP
            # FIXME
            abort
          when CONFIRM_QUIT
            unlock_all_files
            exit
          else
            abort "Unexpected result from get_user_confirmation()"
          end
        end

        # Perform any pre-action commands that the user has requested
        if config.elements['/config/pre']
          process_pre(file, config)
        end

        # If the original "file" is a directory and the user hasn't
        # specifically told us we can overwrite it then abort.
        # 
        # The test is here, rather than a bit earlier where you might
        # expect it, because the pre section may be used to address
        # originals which are directories.  So we don't check until
        # after any pre commands are run.
        if File.directory?(file) && !File.symlink?(file) &&
           !config.elements['/config/file/overwrite_directory']
          abort "Can't proceed, original of #{file} is a directory,\n" +
                "  consider the overwrite_directory flag if appropriate."
        end

        # Give save_orig a definitive answer on whether or not to save the
        # contents of an original directory.
        origpath = save_orig(file, true)
        # Update the history log
        save_history(file)

        # Make a backup in case we need to roll back.  We have no use
        # for a backup if there are no test commands defined (since we
        # only use the backup to roll back if the test fails), so don't
        # bother to create a backup unless there is a test command defined.
        backup = nil
        if config.elements['/config/test_before_post'] ||
           config.elements['/config/test']
          backup = make_backup(file)
          puts "Created backup #{backup}"
        end

        # Make sure the directory tree for this file exists
        filedir = File.dirname(file)
        if !File.directory?(filedir)
          puts "Making directory tree #{filedir}"
          FileUtils.mkpath(filedir) if (!@dryrun)
        end

        # If the new contents are different from the current file,
        # replace the file.
        if compare_file_contents
          if !@dryrun
            # Write out the new contents into a temporary file
            filebase = File.basename(file)
            filedir = File.dirname(file)
            newfile = Tempfile.new(filebase, filedir)

            # Set the proper permissions on the file before putting
            # data into it.
            newfile.chmod(perms)
            begin
              newfile.chown(uid, gid)
            rescue
              raise if Process.euid == 0
            end

            puts "Writing new contents of #{file} to #{newfile}" if (@debug)
            newfile.write(newcontents)
            newfile.close

            # If the current file is not a plain file, remove it.
            # Plain files are left alone so that the replacement is
            # atomic.
            if File.symlink?(file) || (File.exist?(file) && ! File.file?(file))
              puts "Current #{file} is not a plain file, removing it" if (@debug)
              remove_file(file)
            end

            # Move the new file into place
            File.rename(newfile.path, file)
          end
        end

        # Ensure the permissions are set properly
        if compare_permissions
          File.chmod(perms, file) if (!@dryrun)
        end

        # Ensure the ownership is set properly
        if compare_ownership
          begin
            File.chown(uid, gid, file) if (!@dryrun)
          rescue
            raise if Process.euid == 0
          end
        end

        # Perform any test_before_post commands that the user has requested
        if config.elements['/config/test_before_post']
          if !process_test_before_post(file, config)
            restore_backup(file, backup)
            return
          end
        end

        # Perform any post-action commands that the user has requested
        if config.elements['/config/post']
          process_post(file, config)
        end

        # Perform any test commands that the user has requested
        if config.elements['/config/test']
          if !process_test(file, config)
            restore_backup(file, backup)

            # Re-run any post commands
            if config.elements['/config/post']
              process_post(file, config)
            end
          end
        end

        # Clean up the backup, we don't need it anymore
        if config.elements['/config/test_before_post'] ||
           config.elements['/config/test']
          puts "Removing backup #{backup}"
          remove_file(backup) if (!@dryrun);
        end

        # Update the history log again
        save_history(file)

        done = true
      end
    end

    if config.elements['/config/link'] && !done  # Symbolic link

      dest = config.elements['/config/link/dest'].text

      # Perform any setup commands that the user has requested.
      # These are occasionally needed to install software that is
      # required to generate the file (think m4 for sendmail.cf) or to
      # install a package containing a sample config file which we
      # then edit with a script, and thus doing the install in <pre>
      # is too late.
      if config.elements['/config/setup']
        process_setup(file, config)
      end

      compare_link_destination = compare_link_destination(file, dest)
      absdest = File.expand_path(dest, File.dirname(file))

      permstring = config.elements['/config/link/perms'].text
      perms = permstring.oct
      owner = config.elements['/config/link/owner'].text
      group = config.elements['/config/link/group'].text
      uid = lookup_uid(owner)
      gid = lookup_gid(group)

      compare_permissions = compare_permissions(file, perms)
      compare_ownership = compare_ownership(file, uid, gid)

      # Proceed if:
      # - The new link destination differs from the current one
      # - The permissions or ownership requested don't match the
      #   current permissions or ownership
      if !compare_link_destination &&
         !compare_permissions &&
         !compare_ownership
        puts "No change to #{file} necessary" if (@debug)
        done = true
      # Check that the link destination exists, and refuse to create
      # the link unless it does exist or the user told us to go ahead
      # anyway.
      # 
      # Note that the destination may be a relative path, and the
      # target directory may not exist yet, so we have to convert the
      # destination to an absolute path and test that for existence.
      # expand_path should handle paths that are already absolute
      # properly.
      elsif ! File.exist?(absdest) && ! File.symlink?(absdest) &&
            ! config.elements['/config/link/allow_nonexistent_dest']
        puts "Destination #{dest} for link #{file} does not exist," +
             "  consider the allow_nonexistent_dest flag if appropriate."
        done = true
      else
        # Tell the user what we're going to do
        if compare_link_destination
          puts "Linking #{file} -> #{dest}"
        end
        if compare_permissions
          puts "Will set permissions on #{file} to #{permstring}"
        end
        if compare_ownership
          puts "Will set ownership of #{file} to #{uid}:#{gid}"
        end

        # If the user requested interactive mode ask them for
        # confirmation to proceed.
        if @interactive
          case get_user_confirmation()
          when CONFIRM_PROCEED
            # No need to do anything
          when CONFIRM_SKIP
            # FIXME
            abort
          when CONFIRM_QUIT
            unlock_all_files
            exit
          else
            abort "Unexpected result from get_user_confirmation()"
          end
        end

        # Perform any pre-action commands that the user has requested
        if config.elements['/config/pre']
          process_pre(file, config)
        end

        # If the original "file" is a directory and the user hasn't
        # specifically told us we can overwrite it then abort.
        # 
        # The test is here, rather than a bit earlier where you might
        # expect it, because the pre section may be used to address
        # originals which are directories.  So we don't check until
        # after any pre commands are run.
        if File.directory?(file) && !File.symlink?(file) &&
           !config.elements['/config/link/overwrite_directory']
          abort "Can't proceed, original of #{file} is a directory,\n" +
                "  consider the overwrite_directory flag if appropriate."
        end

        # Give save_orig a definitive answer on whether or not to save the
        # contents of an original directory.
        origpath = save_orig(file, true)
        # Update the history log
        save_history(file)

        # Make a backup in case we need to roll back.  We have no use
        # for a backup if there are no test commands defined (since we
        # only use the backup to roll back if the test fails), so don't
        # bother to create a backup unless there is a test command defined.
        backup = nil
        if config.elements['/config/test_before_post'] ||
           config.elements['/config/test']
          backup = make_backup(file)
          puts "Created backup #{backup}"
        end

        # Make sure the directory tree for this link exists
        filedir = File.dirname(file)
        if !File.directory?(filedir)
          puts "Making directory tree #{filedir}"
          FileUtils.mkpath(filedir) if (!@dryrun)
        end

        # Create the link
        if compare_link_destination
          remove_file(file) if (!@dryrun)
          File.symlink(dest, file) if (!@dryrun)
        end

        # Ensure the permissions are set properly
        if compare_permissions
          # Note: lchmod
          File.lchmod(perms, file) if (!@dryrun)
        end

        # Ensure the ownership is set properly
        if compare_ownership
          begin
            # Note: lchown
            File.lchown(uid, gid, file) if (!@dryrun)
          rescue
            raise if Process.euid == 0
          end
        end

        # Perform any test_before_post commands that the user has requested
        if config.elements['/config/test_before_post']
          if !process_test_before_post(file, config)
            restore_backup(file, backup)
            return
          end
        end

        # Perform any post-action commands that the user has requested
        if config.elements['/config/post']
          process_post(file, config)
        end

        # Perform any test commands that the user has requested
        if config.elements['/config/test']
          if !process_test(file, config)
            restore_backup(file, backup)

            # Re-run any post commands
            if config.elements['/config/post']
              process_post(file, config)
            end
          end
        end

        # Clean up the backup, we don't need it anymore
        if config.elements['/config/test_before_post'] ||
           config.elements['/config/test']
          puts "Removing backup #{backup}"
          remove_file(backup) if (!@dryrun);
        end

        # Update the history log again
        save_history(file)

        done = true
      end
    end

    if config.elements['/config/directory'] && !done  # Directory
    
      # A little safety check
      create = config.elements['/config/directory/create']
      abort "No create element found in directory section" if !create
    
      # Perform any setup commands that the user has requested.
      # These are occasionally needed to install software that is
      # required to generate the file (think m4 for sendmail.cf) or to
      # install a package containing a sample config file which we
      # then edit with a script, and thus doing the install in <pre>
      # is too late.
      if config.elements['/config/setup']
        process_setup(file, config)
      end

      permstring = config.elements['/config/directory/perms'].text
      perms = permstring.oct
      owner = config.elements['/config/directory/owner'].text
      group = config.elements['/config/directory/group'].text
      uid = lookup_uid(owner)
      gid = lookup_gid(group)

      compare_permissions = compare_permissions(file, perms)
      compare_ownership = compare_ownership(file, uid, gid)

      # Proceed if:
      # - The current file is not a directory
      # - The permissions or ownership requested don't match the
      #   current permissions or ownership
      if (File.directory?(file) && !File.symlink?(file)) &&
         !compare_permissions &&
         !compare_ownership
        puts "No change to #{file} necessary" if (@debug)
        done = true
      else
        # Tell the user what we're going to do
        if !File.directory?(file) || File.symlink?(file)
          puts "Making directory #{file}"
        end
        if compare_permissions
          puts "Will set permissions on #{file} to #{permstring}"
        end
        if compare_ownership
          puts "Will set ownership of #{file} to #{uid}:#{gid}"
        end

        # If the user requested interactive mode ask them for
        # confirmation to proceed.
        if @interactive
          case get_user_confirmation()
          when CONFIRM_PROCEED
            # No need to do anything
          when CONFIRM_SKIP
            # FIXME
            abort
          when CONFIRM_QUIT
            unlock_all_files
            exit
          else
            abort "Unexpected result from get_user_confirmation()"
          end
        end

        # Perform any pre-action commands that the user has requested
        if config.elements['/config/pre']
          process_pre(file, config)
        end

        # Give save_orig a definitive answer on whether or not to save the
        # contents of an original directory.
        origpath = save_orig(file, false)
        # Update the history log
        save_history(file)

        # Make a backup in case we need to roll back.  We have no use
        # for a backup if there are no test commands defined (since we
        # only use the backup to roll back if the test fails), so don't
        # bother to create a backup unless there is a test command defined.
        backup = nil
        if config.elements['/config/test_before_post'] ||
           config.elements['/config/test']
          backup = make_backup(file)
          puts "Created backup #{backup}"
        end

        # Make sure the directory tree for this directory exists
        filedir = File.dirname(file)
        if !File.directory?(filedir)
          puts "Making directory tree #{filedir}"
          FileUtils.mkpath(filedir) if (!@dryrun)
        end

        # Create the directory
        if !File.directory?(file) || File.symlink?(file)
          remove_file(file) if (!@dryrun)
          Dir.mkdir(file) if (!@dryrun)
        end

        # Ensure the permissions are set properly
        if compare_permissions
          File.chmod(perms, file) if (!@dryrun)
        end

        # Ensure the ownership is set properly
        if compare_ownership
          begin
            File.chown(uid, gid, file) if (!@dryrun)
          rescue
            raise if Process.euid == 0
          end
        end

        # Perform any test_before_post commands that the user has requested
        if config.elements['/config/test_before_post']
          if !process_test_before_post(file, config)
            restore_backup(file, backup)
            return
          end
        end

        # Perform any post-action commands that the user has requested
        if config.elements['/config/post']
          process_post(file, config)
        end

        # Perform any test commands that the user has requested
        if config.elements['/config/test']
          if !process_test(file, config)
            restore_backup(file, backup)

            # Re-run any post commands
            if config.elements['/config/post']
              process_post(file, config)
            end
          end
        end

        # Clean up the backup, we don't need it anymore
        if config.elements['/config/test_before_post'] ||
           config.elements['/config/test']
          puts "Removing backup #{backup}"
          remove_file(backup) if (!@dryrun);
        end

        # Update the history log again
        save_history(file)

        done = true
      end
    end

    if config.elements['/config/delete'] && !done  # Delete whatever is there

      # A little safety check
      proceed = config.elements['/config/delete/proceed']
      abort "No proceed element found in delete section" if !proceed

      # Perform any setup commands that the user has requested.
      # These are occasionally needed to install software that is
      # required to generate the file (think m4 for sendmail.cf) or to
      # install a package containing a sample config file which we
      # then edit with a script, and thus doing the install in <pre>
      # is too late.
      if config.elements['/config/setup']
        process_setup(file, config)
      end

      # Proceed only if the file currently exists
      if !File.exist?(file) && !File.symlink?(file)
        done = true
      else
        # Tell the user what we're going to do
        puts "Removing #{file}"

        # If the user requested interactive mode ask them for
        # confirmation to proceed.
        if @interactive
          case get_user_confirmation()
          when CONFIRM_PROCEED
            # No need to do anything
          when CONFIRM_SKIP
            # FIXME
            abort
          when CONFIRM_QUIT
            unlock_all_files
            exit
          else
            abort "Unexpected result from get_user_confirmation()"
          end
        end

        # Perform any pre-action commands that the user has requested
        if config.elements['/config/pre']
          process_pre(file, config)
        end

        # If the original "file" is a directory and the user hasn't
        # specifically told us we can overwrite it then abort.
        # 
        # The test is here, rather than a bit earlier where you might
        # expect it, because the pre section may be used to address
        # originals which are directories.  So we don't check until
        # after any pre commands are run.
        if File.directory?(file) && !File.symlink?(file) &&
           !config.elements['/config/delete/overwrite_directory']
          abort "Can't proceed, original of #{file} is a directory,\n" +
                "  consider the overwrite_directory flag if appropriate."
        end

        # Give save_orig a definitive answer on whether or not to save the
        # contents of an original directory.
        origpath = save_orig(file, true)
        # Update the history log
        save_history(file)

        # Make a backup in case we need to roll back.  We have no use
        # for a backup if there are no test commands defined (since we
        # only use the backup to roll back if the test fails), so don't
        # bother to create a backup unless there is a test command defined.
        backup = nil
        if config.elements['/config/test_before_post'] ||
           config.elements['/config/test']
          backup = make_backup(file)
          puts "Created backup #{backup}"
        end

        # Remove the file
        remove_file(file) if (!@dryrun)

        # Perform any test_before_post commands that the user has requested
        if config.elements['/config/test_before_post']
          if !process_test_before_post(file, config)
            restore_backup(file, backup)
            return
          end
        end

        # Perform any post-action commands that the user has requested
        if config.elements['/config/post']
          process_post(file, config)
        end

        # Perform any test commands that the user has requested
        if config.elements['/config/test']
          if !process_test(file, config)
            restore_backup(file, backup)

            # Re-run any post commands
            if config.elements['/config/post']
              process_post(file, config)
            end
          end
        end

        # Clean up the backup, we don't need it anymore
        if config.elements['/config/test_before_post'] ||
           config.elements['/config/test']
          puts "Removing backup #{backup}"
          remove_file(backup) if (!@dryrun);
        end

        # Update the history log again
        save_history(file)

        done = true
      end
    end

    @already_processed[file] = true
    unlock_file(file)
  end

  # Returns true if the new contents are different from the current file,
  # or if the file does not currently exist.
  def compare_file_contents(file, newcontents)
    r = false

    # If the file currently exists and is a regular file, check to see
    # if the new contents are different.
    if File.file?(file)
      contents = IO.read(file)
      if newcontents != contents
        r = true
      end
    else
      # The file doesn't currently exist or isn't a regular file
      r = true
    end

    r
  end

  # Returns true if the new link destination is different from the current
  # link, or if the link does not currently exist.
  def compare_link_destination(file, newdest)
    r = false

    # If the file currently exists and is a link, check to see if the
    # new destination is different.
    if File.symlink?(file)
      currentdest = File.readlink(file)
      if currentdest != newdest
        r = true
      end
    else
      # The file doesn't currently exist or isn't a link
      r = true
    end

    r
  end

  def get_orig_sum(file)
    Digest::SHA1.hexdigest(get_orig_contents(file))
  end
  def get_orig_contents(file)
    origpath = save_orig(file)
    orig_contents = nil
    # We only send back the actual original file contents if the original is
    # a regular file, otherwise we send back an empty string.
    if origpath =~ /\.ORIG$/ && File.file?(origpath) && !File.symlink?(origpath)
      orig_contents = IO.read(origpath)
    else
      orig_contents = ''
    end
    orig_contents
  end
  # Save an original copy of the file if that hasn't been done already.
  # Return the path to that original copy.
  def save_orig(file, save_directory_contents=nil)
    origpathbase = File.join(@origbase, file)
    origpath = nil

    if File.exist?("#{origpathbase}.ORIG") || File.symlink?("#{origpathbase}.ORIG")
      origpath = "#{origpathbase}.ORIG"
    elsif File.exist?("#{origpathbase}.NOORIG")
      origpath = "#{origpathbase}.NOORIG"
    elsif File.exist?("#{origpathbase}.TAR")
      origpath = "#{origpathbase}.TAR"
    elsif File.exist?("#{origpathbase}.DIRTMP") && save_directory_contents.nil?
      origpath = "#{origpathbase}.DIRTMP"
    else
      # The original file has not yet been saved
      first_update = true
    
      # Make sure the directory tree for this file exists in the
      # directory we save originals in.
      origdir = File.dirname(origpathbase)
      if !File.directory?(origdir)
        puts "Making directory tree #{origdir}"
        FileUtils.mkpath(origdir) if (!@dryrun)
      end

      if File.directory?(file) && !File.symlink?(file)
        # The original "file" is a directory
        if save_directory_contents
          # Tar up the original directory
          origpath = "#{origpathbase}.TAR"
          filedir = File.dirname(file)
          filebase = File.basename(file)
          puts "Saving contents of original directory #{file}"
          system("cd #{filedir} && tar cf #{origpath} #{filebase}") if (!@dryrun)
          # There may be contents in that directory that the
          # user doesn't want exposed.  Without a way to know,
          # the safest thing is to set restrictive permissions
          # on the tar file.
          File.chmod(0400, origpath) if (!@dryrun)
        elsif save_directory_contents.nil?
          # We have a timing issue, in that we generally save original
          # files before we have the configuration for that file.  For
          # directories that's a problem, because we save directories
          # differently depending on whether we're configuring them to
          # remain a directory, or replacing the directory with something
          # else (file or symlink).  So if we don't have a definitive
          # directive on how to save the directory
          # (i.e. save_directory_contents is nil) then just save a
          # placeholder until we do get a definitive directive.
          origpath = "#{origpathbase}.DIRTMP"
          puts "Creating temporary original placeholder for directory #{file}"
          File.open(origpath, 'w') { |file| } if (!@dryrun)
          first_update = nil
        else
          # Just create a directory in the originals repository with
          # ownership and permissions to match the original directory.
          origpath = "#{origpathbase}.ORIG"
          st = File::Stat.new(file)
          puts "Saving ownership/permissions of original directory"
          Dir.mkdir(origpath, st.mode) if (!@dryrun)
          begin
            File.chown(st.uid, st.gid, origpath) if (!@dryrun)
          rescue
            raise if Process.euid == 0
          end
        end
      elsif File.exist?(file) || File.symlink?(file)
        # The original file exists, and is not a directory
        origpath = "#{origpathbase}.ORIG"
        puts "Saving original file:  #{file} -> #{origpath}"
        filedir = File.dirname(file)
        filebase = File.basename(file)
        recursive_copy_and_rename(filedir, filebase, origpath) if (!@dryrun)
      else
        origpath = "#{origpathbase}.NOORIG"
        # If the original doesn't exist, we need to flag that so
        # that we don't try to save our generated file as an
        # original on future runs
        puts "Original file doesn't exist:  #{file}"
        File.open(origpath, 'w') { |file| } if (!@dryrun)
      end

      if !@first_update.has_key?(file) && !first_update.nil?
        @first_update[file] = first_update
      end
    end

    # Remove the DIRTMP placeholder if it exists and no longer applies
    if origpath !~ /\.DIRTMP$/ && File.exists?("#{origpathbase}.DIRTMP")
      File.delete("#{origpathbase}.DIRTMP")
    end

    origpath
  end

  # This subroutine maintains a revision history for the file in @historybase
  def save_history(file)
    histpath = File.join(@historybase, "#{file}.HISTORY")

    # Make sure the directory tree for this file exists in the
    # directory we save history in.
    histdir = File.dirname(histpath)
    if !File.directory?(histdir)
      puts "Making directory tree #{histdir}"
      FileUtils.mkpath(histdir) if (!@dryrun)
    end
    # Make sure the corresponding RCS directory exists as well.
    histrcsdir = File.join(histdir, 'RCS')
    if !File.directory?(histrcsdir)
      puts "Making directory tree #{histrcsdir}"
      FileUtils.mkpath(histrcsdir) if (!@dryrun)
    end

    # If the history log doesn't exist and we didn't just create the
    # original backup, that indicates that the original backup was made
    # previously but the history log was not started at the same time.
    # There are a variety of reasons why this might be the case (the
    # original was saved by a previous version of etch that didn't have
    # the history log feature, or the original was saved manually by
    # someone) but whatever the reason is we want to use the original
    # backup to start the history log before updating the history log
    # with the current file.
    if !File.exist?(histpath) && !@first_update[file]
      origpath = save_orig(file)
      if File.file?(origpath) && !File.symlink?(origpath)
        puts "Starting history log with saved original file:  " +
          "#{origpath} -> #{histpath}"
        FileUtils.copy(origpath, histpath) if (!@dryrun)
      else
        puts "Starting history log with 'ls -ld' output for " +
          "saved original file:  #{origpath} -> #{histpath}"
        system("ls -ld #{origpath} > #{histpath} 2>&1") if (!@dryrun)
      end
      # Check the newly created history file into RCS
      histbase = File.basename(histpath)
      puts "Checking initial history log into RCS:  #{histpath}"
      if !@dryrun
        # The -m flag shouldn't be needed, but it won't hurt
        # anything and if something is out of sync and an RCS file
        # already exists it will prevent ci from going interactive.
        system(
          "cd #{histdir} && " +
          "ci -q -t-'Original of an etch modified file' " +
          "-m'Update of an etch modified file' #{histbase} && " +
          "co -q -r -kb #{histbase}")
      end
      set_history_permissions(file)
    end
  
    # Copy current file

    # If the file already exists in RCS we need to check out a locked
    # copy before updating it
    histbase = File.basename(histpath)
    rcsstatus = false
    if !@dryrun
      rcsstatus = system("cd #{histdir} && rlog -R #{histbase} > /dev/null 2>&1")
    end
    if rcsstatus
      # set_history_permissions may set the checked-out file
      # writeable, which normally causes co to abort.  Thus the -f
      # flag.
      system("cd #{histdir} && co -q -l -f #{histbase}") if !@dryrun
    end

    if File.file?(file) && !File.symlink?(file)
      puts "Updating history log:  #{file} -> #{histpath}"
      FileUtils.copy(file, histpath) if (!@dryrun)
    else
      puts "Updating history log with 'ls -ld' output:  " +
        "#{histpath}"
      system("ls -ld #{file} > #{histpath} 2>&1") if (!@dryrun)
    end

    # Check the history file into RCS
    puts "Checking history log update into RCS:  #{histpath}"
    if !@dryrun
      # We only need one of the -t or -m flags depending on whether
      # the history log already exists or not, rather than try to
      # keep track of which one we need just specify both and let RCS
      # pick the one it needs.
      system(
        "cd #{histdir} && " +
        "ci -q -t-'Original of an etch modified file' " +
        "-m'Update of an etch modified file' #{histbase} && " +
        "co -q -r -kb #{histbase}")
    end

    set_history_permissions(file)
  end

  # Ensures that the history log file has appropriate permissions to avoid
  # leaking information.
  def set_history_permissions(file)
    origpath = File.join(@origbase, "#{file}.ORIG")
    histpath = File.join(@historybase, "#{file}.HISTORY")

    # We set the permissions to the more restrictive of the original
    # file permissions and the current file permissions.
    origperms = 0777
    if File.exist?(origpath)
      st = File.lstat(origpath)
      # Mask off the file type
      origperms = st.mode & 07777
    end
    fileperms = 0777
    if File.exist?(file)
      st = File.lstat(file)
      # Mask off the file type
      fileperms = st.mode & 07777;
    end

    histperms = origperms & fileperms;

    File.chmod(histperms, histpath) if (!@dryrun)

    # Set the permissions on the RCS file too
    histbase = File.basename(histpath)
    histdir = File.dirname(histpath)
    histrcsdir = "#{histdir}/RCS"
    histrcspath = "#{histrcsdir}/#{histbase},v"
    File.chmod(histperms, histrcspath) if (!@dryrun)
  end

  # Haven't found a Ruby method for creating temporary directories,
  # so create a temporary file and replace it with a directory.
  def tempdir(file)
    filebase = File.basename(file)
    filedir = File.dirname(file)
    tmpfile = Tempfile.new(filebase, filedir)
    tmpdir = tmpfile.path
    tmpfile.close!
    Dir.mkdir(tmpdir)
    tmpdir
  end

  def make_backup(file)
    backup = nil
    filebase = File.basename(file)
    filedir = File.dirname(file)
    if !@dryrun
      backup = tempdir(file)
    else
      # Use a fake placeholder name for use in dry run/debug messages
      backup = "#{file}.XXXX"
    end

    backuppath = File.join(backup, filebase)

    puts "Making backup:  #{file} -> #{backuppath}"
    if !@dryrun
      if File.exist?(file) || File.symlink?(file)
        recursive_copy(filedir, filebase, backup)
      else
        # If there's no file to back up then leave a marker file so
        # that restore_backup does the right thing
        File.open("#{backuppath}.NOORIG", "w") { |file| }
      end
    end

    backup
  end

  def restore_backup(file, backup)
    filebase = File.basename(file)
    backuppath = File.join(backup, filebase)

    puts "Restoring #{backuppath} to #{file}"
    if !@dryrun
      # Clean up whatever we wrote out that caused the test to fail
      remove_file(file)

      # Then restore the backup
      if File.exist?(backuppath) || File.symlink?(backuppath)
        File.rename(backuppath, file)
        remove_file(backup)
      elsif File.exist?("#{backuppath}.NOORIG")
        # There was no original file, so we don't need to do
        # anything except remove our NOORIG marker file
        remove_file(backup)
      else
        abort "No backup found in #{backup} to restore to #{file}"
      end
    end
  end

  def process_setup(file, config)
    exectype = 'setup'
    # Because the setup commands are processed every time etch runs
    # (rather than just when the file has changed, as with pre/post) we
    # don't want to print a message for them unless we're in debug mode.
    puts "Processing #{exectype} commands" if (@debug)
    config.elements.each("/config/#{exectype}/exec") do |setup|
      r = process_exec(exectype, setup.text, file);
      # process_exec currently aborts if a setup or pre command
      # fails.  In case that ever changes make sure we propagate
      # the error.
      return r if (!r)
    end
  end
  def process_pre(file, config)
    exectype = 'pre'
    puts "Processing #{exectype} commands"
    config.elements.each("/config/#{exectype}/exec") do |pre|
      r = process_exec(exectype, pre.text, file);
      # process_exec currently aborts if a setup or pre command
      # fails.  In case that ever changes make sure we propagate
      # the error.
      return r if (!r)
    end
  end
  def process_post(file, config)
    exectype = 'post'
    execs = []
    puts "Processing #{exectype} commands"

    # Add the "exec once" items into the list of commands to process
    # if this is the first time etch has updated this file, and if
    # we haven't already run the command.
    if @first_update[file]
      config.elements.each("/config/#{exectype}/exec_once") do |exec_once|
        if !@exec_already_processed.has_key?(exec_once.text)
          execs << exec_once.text
          @exec_already_processed[exec_once] = true
        else
          puts "Skipping '#{exec_once.text}', it has already " +
            "been executed once this run" if (@debug)
        end
      end
    end

    # Add in the regular exec items as well
    config.elements.each("/config/#{exectype}/exec") do |exec|
      execs << exec.text
    end
  
    # post failures are considered non-fatal, so we ignore the
    # return value from process_exec (it takes care of warning
    # the user).
    execs.each { |exec| process_exec(exectype, exec, file) }
  
    config.elements.each("/config/#{exectype}/exec_once_per_run") do |eopr|
      # Stuff the "exec once per run" nodes into the global hash to
      # be run after we've processed all files.
      puts "Adding '#{eopr.text}' to 'exec once per run' list" if (@debug)
      @exec_once_per_run[eopr.text] = true
    end
  end
  def process_test_before_post(file, config)
    exectype = 'test_before_post'
    puts "Processing #{exectype} commands"
    config.elements.each("/config/#{exectype}/exec") do |test_before_post|
      r = process_exec(exectype, test_before_post.text, file)
      # If the test failed we need to propagate that error
      return r if (!r)
    end
  end
  def process_test(file, config)
    exectype = 'test'
    puts "Processing #{exectype} commands"
    config.elements.each("/config/#{exectype}/exec") do |test|
      r = process_exec(exectype, test.text, file)
      # If the test failed we need to propagate that error
      return r if (!r)
    end
  end

  def process_exec(exectype, exec, file='')
    r = true

    # Because the setup commands are processed every time (rather than
    # just when the file has changed as with pre/post) we don't want to
    # print a message for them.
    puts "  Executing '#{exec}'" if (exectype != 'setup' || @debug)

    # Actually run the command unless we're in a dry run, or if we're in
    # a damp run and the command is a setup command.
    if ! @dryrun || (@dryrun == 'damp' && exectype == 'setup')
      etch_priority = nil

      if exectype == 'post'
        # Etch is likely running at a lower priority than normal.
        # However, we don't want to run post commands at that
        # priority.  If they restart processes (for example,
        # restarting sshd) the restarted process will be left
        # running at that same lower priority.  sshd is particularly
        # nefarious, because further commands started by users via
        # that low priority sshd will also run at low priority.
        # FIXME: Need to figure out how get/setpriority express
        # failure in Ruby
        etch_priority = Process.getpriority(Process::PRIO_USER, 0)
        if etch_priority != 0
          puts "  Etch is running at priority #{etch_priority}, " +
               "temporarily adjusting priority to 0 to run post command" if (@debug)
          Process.setpriority(Process::PRIO_USER, 0, 0)
        end
      end

      r = system(exec)

      if exectype == 'post'
        if etch_priority != 0
          puts "  Returning priority to #{etch_priority}" if (@debug)
          Process.setpriority(Process::PRIO_USER, 0, etch_priority)
        end
      end
    end

    # If the command exited with error
    if !r
      # We don't normally print the command we're executing for setup
      # commands (see above).  But that makes it hard to figure out
      # what's going on if it fails.  So include the command in the
      # message if there was a failure.
      execmsg = ''
      execmsg = "'#{exec}' " if (exectype == 'setup')

      # Normally we include the filename of the file that this command
      # is associated with in the messages we print.  But for "exec once
      # per run" commands that doesn't apply.  Assemble a variable
      # that has the filename if we have it, to be included in the
      # error message we're going to print.
      filemsg = ''
      filemsg = "for #{file} " if (!file.empty?)

      # Setup and pre commands are almost always used to install
      # software prerequisites, and bad things generally happen if
      # those software installs fail.  So consider it a fatal error if
      # that occurs.
      if exectype == 'setup' || exectype == 'pre'
        abort "    Setup/Pre command " + execmsg + filemsg +
          "exited with non-zero value"
      # Post commands are generally used to restart services.  While
      # it is unfortunate if they fail, there is little to be gained
      # by having etch exit if they do so.  So simply warn if a post
      # command fails.
      elsif exectype == 'post'
        puts "    Post command " + execmsg + filemsg +
          "exited with non-zero value"
      # For test commands we need to warn the user and then return a
      # value indicating the failure so that a rollback can be
      # performed.
      else
        puts "    Test command " + execmsg + filemsg +
          "exited with non-zero value"
      end
    end

    r
  end

  def lookup_uid(user)
    uid = nil
    if user =~ /^\d+$/
      # If the user was specified as a numeric UID, use it directly.
      uid = user
    else
      # Otherwise attempt to look up the username to get a UID.
      # Default to UID 0 if the username can't be found.
      pw = Etc.getpwnam(user)
      if pw
        uid = pw.uid
      else
        puts "config.xml requests user #{user}, but that user can't be found.  Using UID 0."
        uid = 0
      end
    end

    uid.to_i
  end

  def lookup_gid(group)
    gid = nil
    if group =~ /^\d+$/
      # If the group was specified as a numeric GID, use it directly.
      gid = group
    else
      # Otherwise attempt to look up the group to get a GID.  Default
      # to GID 0 if the group can't be found.
      gr = Etc.getgrnam(group)
      if gr
        gid = gr.gid
      else
        puts "config.xml requests group #{group}, but that group can't be found.  Using GID 0."
        gid = 0
      end
    end

    gid.to_i
  end

  # Returns false if the permissions of the given file match the given
  # permissions, true otherwise.
  def compare_permissions(file, perms)
    if ! File.exist?(file)
      return true
    end

    st = File.lstat(file)
    # Mask off the file type
    fileperms = st.mode & 07777
    if perms == fileperms
      return false
    else
      return true
    end
  end

  # Returns false if the ownership of the given file match the given UID
  # and GID, true otherwise.
  def compare_ownership(file, uid, gid)
    if ! File.exist?(file)
      return true
    end

    st = File.lstat(file)
    if st.uid == uid && st.gid == gid
      return false
    else
      return true
    end
  end

  def get_user_confirmation
    while true
      print "Proceed/Skip/Quit? [p|s|q] "
      response = $stdin.gets.chomp
      if response == 'p'
        return CONFIRM_PROCEED
      elsif response == 's'
        return CONFIRM_SKIP
      elsif response == 'q'
        return CONFIRM_QUIT
      end
    end
  end

  def remove_file(file)
    if ! File.exist?(file) && ! File.symlink?(file)
      puts "remove_file: #{file} doesn't exist" if (@debug)
    else
      FileUtils.rmtree(file, :secure => true)
    end
  end

  def recursive_copy(sourcedir, sourcefile, destdir)
    # Note that cp -p will follow symlinks.  GNU cp has a -d option to
    # prevent that, but Solaris cp does not, so we resort to cpio.
    # GNU cpio has a --quiet option, but Solaris cpio does not.  Sigh.
    system("cd #{sourcedir} && find #{sourcefile} | cpio -pdum #{destdir}") or
      abort "Copy #{sourcedir}/#{sourcefile} to #{destdir} failed"
  end
  def recursive_copy_and_rename(sourcedir, sourcefile, destname)
    tmpdir = tempdir(destname)
    recursive_copy(sourcedir, sourcefile, tmpdir)
    File.rename(File.join(tmpdir, sourcefile), destname)
    Dir.delete(tmpdir)
  end

  def lock_file(file)
    lockpath = File.join(@lockbase, "#{file}.LOCK")

    # Make sure the directory tree for this file exists in the
    # lock directory
    lockdir = File.dirname(lockpath)
    if ! File.directory?(lockdir)
      puts "Making directory tree #{lockdir}" if (@debug)
      FileUtils.mkpath(lockdir) if (!@dryrun)
    end

    return if (@dryrun)

    # Make 30 attempts (1s sleep after each attempt)
    30.times do |i|
      begin
        fd = IO::sysopen(lockpath, Fcntl::O_WRONLY|Fcntl::O_CREAT|Fcntl::O_EXCL)
        puts "Lock acquired for #{file}" if (@debug)
        f = IO.open(fd) { |f| f.puts $$ }
        @locked_files[file] = true
        return
      rescue Errno::EEXIST
        puts "Attempt to acquire lock for #{file} failed, sleeping 1s"
        sleep 1
      end
    end

    abort "Unable to acquire lock for #{file} after repeated attempts"
  end

  def unlock_file(file)
    lockpath = File.join(@lockbase, "#{file}.LOCK")

    # Since we don't create lock files in dry run mode the rest of this
    # method won't behave properly
    return if (@dryrun)

    if File.exist?(lockpath)
      pid = File.new(lockpath).gets.chomp.to_i
      if pid == $$
        puts "Unlocking #{file}" if (@debug)
        File.delete(lockpath)
        @locked_files.delete(file)
      else
        # This shouldn't happen, if it does it's a bug
        abort "Asked to unlock #{file} which is locked by another process (pid #{pid})"
      end
    else
      # This shouldn't happen either
      warn "Lock for #{file} lost"
      @locked_files.delete(file)
    end
  end

  def unlock_all_files
    @locked_files.each_key { |file| unlock_file(file) }
  end
  
  # Any etch lockfiles more than a couple hours old are most likely stale
  # and can be removed.  If told to force we remove all lockfiles.
  def remove_stale_lock_files(force=false)
    twohoursago = Time.at(Time.now - 60 * 60 * 2)
    Find.find(@lockbase) do |file|
      next unless file =~ /\.LOCK$/
      next unless File.file?(file)

      if force || File.mtime(file) < twohoursago
        puts "Removing stale lock file #{file}"
        File.delete(file)
      end
    end
  end
  
  def reset_already_processed
    @already_processed.clear
  end

end
