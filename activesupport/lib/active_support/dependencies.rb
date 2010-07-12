require 'set'
require 'active_support/inflector'

module ActiveSupport # :nodoc:
  # Documentation goes here.
  module Dependencies
    # Should we turn on Ruby warnings on the first load of dependent files?
    mattr_accessor :warnings_on_first_load
    self.warnings_on_first_load = false

    # All files ever loaded.
    mattr_accessor :history
    self.history = Set.new

    # All files currently loaded.
    mattr_accessor :loaded
    self.loaded = Set.new

    # Should we load files or require them?
    mattr_accessor :mechanism
    self.mechanism = ENV['NO_RELOAD'] ? :require : :load

    # An array of qualified constant names that have been loaded. Adding a name to
    # this array will cause it to be unloaded the next time Dependencies are cleared.
    mattr_accessor :autoloaded_constants
    self.autoloaded_constants = []

    # The set of directories from which we may automatically load files. Files
    # under these directories will be reloaded on each request in development mode,
    # unless the directory also appears in autoload_once_paths.
    mattr_accessor :autoload_paths
    self.autoload_paths = []

    # The set of directories from which automatically loaded constants are loaded
    # only once. All directories in this set must also be present in +autoload_paths+.
    mattr_accessor :autoload_once_paths
    self.autoload_once_paths = []

    # An array of constant names that need to be unloaded on every request. Used
    # to allow arbitrary constants to be marked for unloading.
    mattr_accessor :explicitly_unloadable_constants
    self.explicitly_unloadable_constants = []

    # The logger is used for generating information on the action run-time (including benchmarking) if available.
    # Can be set to nil for no logging. Compatible with both Ruby's own Logger and Log4r loggers.
    mattr_accessor :logger

    # Set to true to enable logging of const_missing and file loads
    mattr_accessor :log_activity
    self.log_activity = false

    mattr_accessor :world_reload_count
    self.world_reload_count = 0

    mattr_accessor :default_strategy
    self.default_strategy = :world

    module Tools # :nodoc:
      def self.included(base) # :nodoc:
        base.extend(self)
      end

      # Convert the provided const desc to a qualified constant name (as a string).
      # A module, class, symbol, or string may be provided.
      def to_constant_name(desc) #:nodoc:
        name = case desc
        when String then desc.sub(/^(::)?(Object)?::/, '')
        when Symbol then desc.to_s
        when Module, Constant
          desc.name.presence ||
          raise(ArgumentError, "Anonymous modules have no name to be referenced by")
        else raise TypeError, "Not a valid constant descriptor: #{desc.inspect}"
        end
      end

      def logger
        Dependencies.logger
      end

      def log_activity?
        Dependencies.log_activity
      end

      def autoloaded_constants
        Dependencies.autoloaded_constants
      end

      if Module.method(:const_defined?).arity == 1
        # Does this module define this constant?
        # Wrapper to accommodate changing Module#const_defined? in Ruby 1.9
        def local_const_defined?(mod, const)
          mod.const_defined?(const)
        end
      else
        def local_const_defined?(mod, const) #:nodoc:
          mod.const_defined?(const, false)
        end
      end

      protected

      def log_call(*args)
        if logger && log_activity?
          arg_str = args.collect { |arg| arg.inspect } * ', '
          /in `([a-z_\?\!]+)'/ =~ caller(1).first
          selector = $1 || '<unknown>'
          log "called #{selector}(#{arg_str})"
        end
      end

      def log(msg)
        if logger && log_activity?
          logger.debug "Dependencies: #{msg}"
        end
      end
    end

    module Strategies # :nodoc:
      module World
      end

      module Sloppy
        include World
      end

      module MonkeyPatch
      end
    end

    class Constant
      extend Enumerable
      include Tools

      mattr_accessor :map
      self.map ||= {}

      def self.available?(name)
        map.include? to_constant_name(name)
      end

      def self.new(name)
        return name if Constant === name
        name = to_constant_name(name)
        map[name] ||= super
      end

      class << self
        alias [] new
      end

      attr_reader :name, :constant, :parent, :local_name

      def initialize(name)
        @name = name
        if name =~ /::([^:]+)\Z/
          @parent, @local_name = Constant[$`], $1
        elsif name == 'Object'
          @parent, @local_name = self, 'Object'
        else
          @parent, @local_name = Constant[Object], name
        end
        unless @constant = qualified_const
          @parent.load_constant(local_name)
        end
      end

      def qualified_const_defined?
        !!qualified_const
      end

      def qualified_const
        @names ||= name.split("::")
        @names.inject(Object) do |mod, name|
          return unless local_const_defined?(mod, name)
          mod.const_get(name)
        end
      end

      def active?
        qualified_const == constant
      end

      def autoloaded?
        !constant.anonymous? and qualified_const_defined? and autoloaded_constants.include?(name)
      end

      def load_constant(local_name)
        complete_name = "#{name}::#{local_name}"
        if Constant.available? complete_name
          Constant[complete_name].reload
        else
          raise NotImplementedError
        end
      end
    end

    extend self
    include Tools

    def autoloaded?(desc)
      Constant[desc].autoloaded?
    end

    def clear
      log_call
      loaded.clear
      remove_unloadable_constants!
    end

    def load_missing_constant(from_mod, const_name)
      Constant[from_mod].load_constant(const_name)
    end
  end
end
