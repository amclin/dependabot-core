# frozen_string_literal: true

require "excon"
require "toml-rb"
require "open3"
require "dependabot/dependency"
require "dependabot/errors"
require "dependabot/shared_helpers"
require "dependabot/python/file_parser"
require "dependabot/python/file_parser/python_requirement_parser"
require "dependabot/python/file_updater/pipfile_preparer"
require "dependabot/python/file_updater/setup_file_sanitizer"
require "dependabot/python/update_checker"
require "dependabot/python/python_versions"
require "dependabot/python/native_helpers"
require "dependabot/python/name_normaliser"
require "dependabot/python/version"

# rubocop:disable Metrics/ClassLength
module Dependabot
  module Python
    class UpdateChecker
      # This class does version resolution for Pipfiles. Its current approach
      # is somewhat crude:
      # - Unlock the dependency we're checking in the Pipfile
      # - Freeze all of the other dependencies in the Pipfile
      # - Run `pipenv lock` and see what the result is
      #
      # Unfortunately, Pipenv doesn't resolve how we'd expect - it appears to
      # just raise if the latest version can't be resolved. Knowing that is
      # still better than nothing, though.
      class PipenvVersionResolver
        GIT_DEPENDENCY_UNREACHABLE_REGEX =
          /command: git clone -q (?<url>[^\s]+).* /.freeze
        GIT_REFERENCE_NOT_FOUND_REGEX =
          %r{git checkout -q (?<tag>[^\n]+)\n[^\n]*/(?<name>.*?)(\\n'\]|$)}m.
          freeze
        UNSUPPORTED_DEPS = %w(pyobjc).freeze
        UNSUPPORTED_DEP_REGEX =
          /"python setup\.py egg_info".*(?:#{UNSUPPORTED_DEPS.join("|")})/.
          freeze

        attr_reader :dependency, :dependency_files, :credentials

        def initialize(dependency:, dependency_files:, credentials:)
          @dependency               = dependency
          @dependency_files         = dependency_files
          @credentials              = credentials
        end

        def latest_resolvable_version(requirement: nil)
          version_string =
            fetch_latest_resolvable_version_string(requirement: requirement)

          version_string.nil? ? nil : Python::Version.new(version_string)
        end

        def resolvable?(version:)
          @resolvable ||= {}
          return @resolvable[version] if @resolvable.key?(version)

          if fetch_latest_resolvable_version_string(requirement: "==#{version}")
            @resolvable[version] = true
          else
            @resolvable[version] = false
          end
        end

        private

        def fetch_latest_resolvable_version_string(requirement:)
          @latest_resolvable_version_string ||= {}
          if @latest_resolvable_version_string.key?(requirement)
            return @latest_resolvable_version_string[requirement]
          end

          @latest_resolvable_version_string[requirement] ||=
            SharedHelpers.in_a_temporary_directory do
              SharedHelpers.with_git_configured(credentials: credentials) do
                write_temporary_dependency_files(updated_req: requirement)
                install_required_python

                # Shell out to Pipenv, which handles everything for us.
                # Whilst calling `lock` avoids doing an install as part of the
                # pipenv flow, an install is still done by pip-tools in order
                # to resolve the dependencies. That means this is slow.
                run_pipenv_command("pyenv exec pipenv lock")

                updated_lockfile = JSON.parse(File.read("Pipfile.lock"))

                fetch_version_from_parsed_lockfile(updated_lockfile)
              end
            rescue SharedHelpers::HelperSubprocessFailed => e
              handle_pipenv_errors(e)
            end
        end

        def fetch_version_from_parsed_lockfile(updated_lockfile)
          if dependency.requirements.any?
            group = dependency.requirements.first[:groups].first
            deps = updated_lockfile[group] || {}

            version =
              deps.transform_keys { |k| normalise(k) }.
              dig(dependency.name, "version")&.
              gsub(/^==/, "")

            return version
          end

          Python::FileParser::DEPENDENCY_GROUP_KEYS.each do |keys|
            deps = updated_lockfile[keys.fetch(:lockfile)] || {}
            version =
              deps.transform_keys { |k| normalise(k) }.
              dig(dependency.name, "version")&.
              gsub(/^==/, "")

            return version if version
          end

          # If the sub-dependency no longer appears in the lockfile return nil
          nil
        end

        # rubocop:disable Metrics/CyclomaticComplexity
        # rubocop:disable Metrics/PerceivedComplexity
        # rubocop:disable Metrics/AbcSize
        # rubocop:disable Metrics/MethodLength
        def handle_pipenv_errors(error)
          if error.message.include?("no version found at all") ||
             error.message.include?("Invalid specifier:") ||
             error.message.include?("Max retries exceeded")
            msg = clean_error_message(error.message)
            raise if msg.empty?

            raise DependencyFileNotResolvable, msg
          end

          if error.message.match?(UNSUPPORTED_DEP_REGEX)
            msg = "Dependabot detected a dependency that can't be built on "\
                  "linux. Currently, all Dependabot builds happen on linux "\
                  "boxes, so there is no way for Dependabot to resolve your "\
                  "dependency files.\n\n"\
                  "Unless you think Dependabot has made a mistake (please "\
                  "tag us if so) you may wish to disable Dependabot on this "\
                  "repo."
            raise DependencyFileNotResolvable, msg
          end

          if error.message.include?("Could not find a version") ||
             error.message.include?("is not a python version")
            check_original_requirements_resolvable
          end

          if error.message.include?('Command "python setup.py egg_info"') ||
             error.message.include?("exit status 1: python setup.py egg_info")
            # The latest version of the dependency we're updating is borked
            # (because it has an unevaluatable setup.py). Skip the update.
            return if check_original_requirements_resolvable
          end

          if error.message.include?("UnsupportedPythonVersion") &&
             user_specified_python_requirement
            check_original_requirements_resolvable

            # The latest version of the dependency we're updating to needs a
            # different Python version. Skip the update.
            return if error.message.match?(/#{Regexp.quote(dependency.name)}/i)
          end

          if error.message.match?(GIT_DEPENDENCY_UNREACHABLE_REGEX)
            url = error.message.match(GIT_DEPENDENCY_UNREACHABLE_REGEX).
                  named_captures.fetch("url")
            raise GitDependenciesNotReachable, url
          end

          if error.message.match?(GIT_REFERENCE_NOT_FOUND_REGEX)
            name = error.message.match(GIT_REFERENCE_NOT_FOUND_REGEX).
                   named_captures.fetch("name")
            raise GitDependencyReferenceNotFound, name
          end

          raise unless error.message.include?("could not be resolved")
        end
        # rubocop:enable Metrics/CyclomaticComplexity
        # rubocop:enable Metrics/PerceivedComplexity
        # rubocop:enable Metrics/AbcSize
        # rubocop:enable Metrics/MethodLength

        # Needed because Pipenv's resolver isn't perfect.
        # Note: We raise errors from this method, rather than returning a
        # boolean, so that all deps for this repo will raise identical
        # errors when failing to update
        def check_original_requirements_resolvable
          SharedHelpers.in_a_temporary_directory do
            SharedHelpers.with_git_configured(credentials: credentials) do
              write_temporary_dependency_files(update_pipfile: false)

              run_pipenv_command("pyenv exec pipenv lock")

              true
            rescue SharedHelpers::HelperSubprocessFailed => e
              handle_pipenv_errors_resolving_original_reqs(e)
            end
          end
        end

        def handle_pipenv_errors_resolving_original_reqs(error)
          if error.message.include?("Could not find a version")
            msg = clean_error_message(error.message)
            msg.gsub!(/\s+\(from .*$/, "")
            raise if msg.empty?

            raise DependencyFileNotResolvable, msg
          end

          if error.message.include?("is not a python version")
            msg = "Pipenv does not support specifying Python ranges "\
              "(see https://github.com/pypa/pipenv/issues/1050 for more "\
              "details)."
            raise DependencyFileNotResolvable, msg
          end

          if error.message.include?("UnsupportedPythonVersion") &&
             user_specified_python_requirement
            msg = clean_error_message(error.message).
                  lines.take_while { |l| !l.start_with?("File") }.join.strip
            raise if msg.empty?

            raise DependencyFileNotResolvable, msg
          end

          # Raise an unhandled error, as this could be a problem with
          # Dependabot's infrastructure, rather than the Pipfile
          raise
        end

        def clean_error_message(message)
          # Pipenv outputs a lot of things to STDERR, so we need to clean
          # up the error message
          msg_lines = message.lines
          msg = msg_lines.
                take_while { |l| !l.start_with?("During handling of") }.
                drop_while do |l|
                  next false if l.start_with?("CRITICAL:")
                  next false if l.start_with?("ERROR:")
                  next false if l.start_with?("packaging.specifiers")
                  next false if l.start_with?("pipenv.patched.notpip._internal")
                  next false if l.include?("Max retries exceeded")

                  true
                end.join.strip

          # We also need to redact any URLs, as they may include credentials
          msg.gsub(/http.*?(?=\s)/, "<redacted>")
        end

        def write_temporary_dependency_files(updated_req: nil,
                                             update_pipfile: true)
          dependency_files.each do |file|
            path = file.name
            FileUtils.mkdir_p(Pathname.new(path).dirname)
            File.write(path, file.content)
          end

          # Overwrite the .python-version with updated content
          File.write(".python-version", python_version)

          setup_files.each do |file|
            path = file.name
            FileUtils.mkdir_p(Pathname.new(path).dirname)
            File.write(path, sanitized_setup_file_content(file))
          end

          setup_cfg_files.each do |file|
            path = file.name
            FileUtils.mkdir_p(Pathname.new(path).dirname)
            File.write(path, "[metadata]\nname = sanitized-package\n")
          end
          return unless update_pipfile

          # Overwrite the pipfile with updated content
          File.write(
            "Pipfile",
            pipfile_content(updated_requirement: updated_req)
          )
        end

        def install_required_python
          # Initialize a git repo to appease pip-tools
          begin
            run_command("git init") if setup_files.any?
          rescue Dependabot::SharedHelpers::HelperSubprocessFailed
            nil
          end

          if run_command("pyenv versions").include?("#{python_version}\n")
            return
          end

          requirements_path = NativeHelpers.python_requirements_path
          run_command("pyenv install -s #{python_version}")
          run_command("pyenv exec pip install -r "\
                      "#{requirements_path}")
        end

        def sanitized_setup_file_content(file)
          @sanitized_setup_file_content ||= {}
          @sanitized_setup_file_content[file.name] ||=
            Python::FileUpdater::SetupFileSanitizer.
            new(setup_file: file, setup_cfg: setup_cfg(file)).
            sanitized_content
        end

        def setup_cfg(file)
          config_name = file.name.sub(/\.py$/, ".cfg")
          dependency_files.find { |f| f.name == config_name }
        end

        def pipfile_content(updated_requirement:)
          content = pipfile.content
          content = freeze_other_dependencies(content)
          content = set_target_dependency_req(content, updated_requirement)
          content = add_private_sources(content)
          content
        end

        def freeze_other_dependencies(pipfile_content)
          Python::FileUpdater::PipfilePreparer.
            new(pipfile_content: pipfile_content, lockfile: lockfile).
            freeze_top_level_dependencies_except([dependency])
        end

        def set_target_dependency_req(pipfile_content, updated_requirement)
          return pipfile_content unless updated_requirement

          pipfile_object = TomlRB.parse(pipfile_content)

          %w(packages dev-packages).each do |type|
            names = pipfile_object[type]&.keys || []
            pkg_name = names.find { |nm| normalise(nm) == dependency.name }
            next unless pkg_name || subdep_type?(type)

            pkg_name ||= dependency.name
            if pipfile_object.dig(type, pkg_name).is_a?(Hash)
              pipfile_object[type][pkg_name]["version"] = updated_requirement
            else
              pipfile_object[type][pkg_name] = updated_requirement
            end
          end

          TomlRB.dump(pipfile_object)
        end

        def subdep_type?(type)
          return false if dependency.top_level?

          lockfile_type = Python::FileParser::DEPENDENCY_GROUP_KEYS.
                          find { |i| i.fetch(:pipfile) == type }.
                          fetch(:lockfile)

          JSON.parse(lockfile.content).
            fetch(lockfile_type, {}).
            keys.any? { |k| normalise(k) == dependency.name }
        end

        def add_private_sources(pipfile_content)
          Python::FileUpdater::PipfilePreparer.
            new(pipfile_content: pipfile_content).
            replace_sources(credentials)
        end

        def python_version
          @python_version ||= python_version_from_supported_versions
        end

        def python_version_from_supported_versions
          requirement_string =
            if @using_python_two then "2.7.*"
            elsif user_specified_python_requirement
              parts = user_specified_python_requirement.split(".")
              parts.fill("*", (parts.length)..2).join(".")
            else PythonVersions::PRE_INSTALLED_PYTHON_VERSIONS.first
            end

          # Ideally, the requirement is satisfied by a Python version we support
          requirement = Python::Requirement.new(requirement_string)
          version =
            PythonVersions::SUPPORTED_VERSIONS_TO_ITERATE.
            find { |v| requirement.satisfied_by?(Python::Version.new(v)) }
          return version if version

          # If not, and changing the patch version would fix things, we do that
          # as the patch version is unlikely to affect resolution
          requirement =
            Python::Requirement.new(requirement_string.gsub(/\.\d+$/, ".*"))
          version =
            PythonVersions::SUPPORTED_VERSIONS_TO_ITERATE.
            find { |v| requirement.satisfied_by?(Python::Version.new(v)) }
          return version if version

          # Otherwise we have to raise, giving details of the Python versions
          # that Dependabot supports
          msg = "Dependabot detected the following Python requirement "\
                "for your project: '#{requirement_string}'.\n\nCurrently, the "\
                "following Python versions are supported in Dependabot: "\
                "#{PythonVersions::SUPPORTED_VERSIONS.join(', ')}."
          raise DependencyFileNotResolvable, msg
        end

        def user_specified_python_requirement
          python_requirement_parser.user_specified_requirements.first
        end

        def python_requirement_parser
          @python_requirement_parser ||=
            FileParser::PythonRequirementParser.new(
              dependency_files: dependency_files
            )
        end

        def run_command(command, env: {})
          start = Time.now
          command = SharedHelpers.escape_command(command)
          stdout, process = Open3.capture2e(env, command)
          time_taken = Time.now - start

          return stdout if process.success?

          raise SharedHelpers::HelperSubprocessFailed.new(
            message: stdout,
            error_context: {
              command: command,
              time_taken: time_taken,
              process_exit_value: process.to_s
            }
          )
        end

        def run_pipenv_command(command, env: pipenv_env_variables)
          run_command("pyenv local #{python_version}")
          run_command(command, env: env)
        rescue SharedHelpers::HelperSubprocessFailed => e
          original_error ||= e
          msg = e.message

          relevant_error =
            if may_be_using_wrong_python_version?(msg) then original_error
            else e
            end

          raise relevant_error unless may_be_using_wrong_python_version?(msg)
          raise relevant_error if python_version.start_with?("2")

          # Clear the existing virtualenv, so that we use the new Python version
          run_command("pyenv local #{python_version}")
          run_command("pyenv exec pipenv --rm")

          @python_version = "2.7.16"
          retry
        ensure
          @python_version = nil
          FileUtils.remove_entry(".python-version", true)
        end

        def may_be_using_wrong_python_version?(error_message)
          return false if user_specified_python_requirement
          return true if error_message.include?("UnsupportedPythonVersion")
          return true if error_message.include?("at matches #{dependency.name}")

          error_message.include?('Command "python setup.py egg_info" failed') ||
            error_message.include?("exit status 1: python setup.py egg_info")
        end

        def pipenv_env_variables
          {
            "PIPENV_YES" => "true",       # Install new Python ver if needed
            "PIPENV_MAX_RETRIES" => "3",  # Retry timeouts
            "PIPENV_NOSPIN" => "1",       # Don't pollute logs with spinner
            "PIPENV_TIMEOUT" => "600",    # Set install timeout to 10 minutes
            "PIP_DEFAULT_TIMEOUT" => "60" # Set pip timeout to 1 minute
          }
        end

        def normalise(name)
          NameNormaliser.normalise(name)
        end

        def pipfile
          dependency_files.find { |f| f.name == "Pipfile" }
        end

        def lockfile
          dependency_files.find { |f| f.name == "Pipfile.lock" }
        end

        def setup_files
          dependency_files.select { |f| f.name.end_with?("setup.py") }
        end

        def setup_cfg_files
          dependency_files.select { |f| f.name.end_with?("setup.cfg") }
        end
      end
    end
  end
end
# rubocop:enable Metrics/ClassLength
