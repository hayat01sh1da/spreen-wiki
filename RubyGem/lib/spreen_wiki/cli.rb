# frozen_string_literal: true
# rbs_inline: enabled

require 'optparse'
require_relative 'version'
require_relative 'home'
require_relative 'sidebar'
require_relative 'unknown_wiki_count_list_exporter'
require_relative 'unknown_wiki_list_exporter_for_llm'

module SpreenWiki
  # Command line interface behind the `wiki-organise` executable:
  # `wiki-organise <update|count-report|llm-export> [options]`.
  class CLI
    HELP = <<~HELP
      Usage: wiki-organise <command> [options]

      Commands:
        update        Regenerate Home.md and _Sidebar.md from the wiki tree
        count-report  Export a count report of the unknown-namespace wikis
        llm-export    Export the unknown-namespace wiki list for an LLM
        version       Print the version

      Run `wiki-organise <command> --help` to list the command's options.
    HELP

    # Flags shared by every command, mapped to the keyword arguments of the
    # underlying classes. --exclude and the per-command flags are wired up
    # separately because they need a type or a fixed value.
    COMMON_OPTIONS = {
      '--path PATH' => [:base_path, 'Path to the wiki clone (default: current directory)'],
      '--group-by GROUP_BY' => [:group_by, 'Grouping criteria (default: Owner)'],
      '--language LANGUAGE' => [:language, 'Language of the labels (default: English)'],
      '--org ORGANISATION' => [:organisation, 'GitHub organisation/user hosting the wiki'],
      '--repo REPOSITORY' => [:repository, 'GitHub repository whose wiki is organised'],
      '--wiki-url URL' => [:wiki_url, 'Wiki URL (overrides the one derived from --org/--repo)'],
      '--template-dir DIR' => [:template_dir, 'Directory of <group_by>/<language>.md Home templates'],
      '--config FILE' => [:config_path, 'Config file path (default: <path>/.spreen.yml)']
    }.freeze

    # @rbs argv: Array[String]
    # @rbs return: Integer
    def self.start(argv = ARGV)
      new(argv).run
    end

    # @rbs argv: Array[String]
    # @rbs return: void
    def initialize(argv)
      @argv    = argv.dup
      @options = { base_path: Dir.pwd, group_by: 'Owner', language: 'English', home_overflow: 'false' }
    end

    # @rbs return: Integer
    def run
      command = argv.shift
      case command
      when 'update', 'count-report', 'llm-export' then execute(command)
      when 'version', '--version', '-v'           then print_version
      when nil, 'help', '--help', '-h'            then print_help(command)
      else unknown_command(command)
      end
    end

    private

    attr_reader :argv, :options

    # @rbs command: String
    # @rbs return: Integer
    def execute(command)
      parser(command).parse!(argv)
      __send__(command.tr('-', '_'))
      0
    rescue ArgumentError, OptionParser::ParseError => e
      warn e.message
      1
    end

    # @rbs return: Integer
    def print_version
      puts VERSION
      0
    end

    # @rbs command: String?
    # @rbs return: Integer
    def print_help(command)
      puts HELP
      command.nil? ? 1 : 0
    end

    # @rbs command: String
    # @rbs return: Integer
    def unknown_command(command)
      warn "Unknown command: `#{command}`"
      warn HELP
      1
    end

    # @rbs return: void
    def update
      wiki_url = Home.run(**options)
      Sidebar.run(**options)
      puts 'Updated Home.md and _Sidebar.md.'
      puts "Check them out at '#{wiki_url}' !!" if wiki_url
    end

    # @rbs return: void
    def count_report
      count_list_by_namespace, path_to_export = UnknownWikiCountListExporter.run(**options)
      puts count_list_by_namespace
      puts "Exported the unknown wiki count report to '#{path_to_export}'."
    end

    # @rbs return: void
    def llm_export
      path_to_export = UnknownWikiListExporterForLLM.run(**options)
      puts "Exported the unknown wiki list for LLM to '#{path_to_export}'."
    end

    # @rbs command: String
    # @rbs return: OptionParser
    def parser(command)
      OptionParser.new("Usage: wiki-organise #{command} [options]") do |opt|
        add_common_options(opt)
        add_command_options(opt, command)
      end
    end

    # @rbs opt: OptionParser
    # @rbs return: void
    def add_common_options(opt)
      COMMON_OPTIONS.each do |flag, (key, description)|
        opt.on(flag, description) { |value| options[key] = value }
      end
      opt.on('--exclude DIR1,DIR2', Array, 'Directories to skip while scanning') do |dirs|
        options[:excluded_dirs] = dirs
      end
    end

    # @rbs opt: OptionParser
    # @rbs command: String
    # @rbs return: void
    def add_command_options(opt, command)
      if command == 'update'
        opt.on('--overflow', 'Split Home into per-namespace pages under wikis-by-owner/') do
          options[:home_overflow] = 'true'
        end
      else
        opt.on('--output FILENAME', 'Export filename (relative to --path unless absolute)') do |filename|
          options[:output] = filename
        end
      end
    end
  end
end
