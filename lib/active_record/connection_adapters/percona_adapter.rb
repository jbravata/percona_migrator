require 'active_record/connection_adapters/abstract_mysql_adapter'
require 'active_record/connection_adapters/statement_pool'
require 'active_record/connection_adapters/mysql2_adapter'
require 'percona_migrator'
require 'forwardable'

module ActiveRecord
  class Base
    # Establishes a connection to the database that's used by all Active
    # Record objects.
    def self.percona_connection(config)
      mysql2_connection = mysql2_connection(config)

      verbose = ActiveRecord::Migration.verbose
      percona_logger = PerconaMigrator::LoggerFactory.build(verbose: verbose)
      cli_generator = PerconaMigrator::CliGenerator.new(config)

      runner = PerconaMigrator::Runner.new(
        percona_logger,
        cli_generator,
        mysql2_connection
      )

      connection_options = { mysql_adapter: mysql2_connection }

      ConnectionAdapters::PerconaMigratorAdapter.new(
        runner,
        logger,
        connection_options,
        config
      )
    end
  end

  module ConnectionAdapters
    class PerconaMigratorAdapter < AbstractMysqlAdapter

      class Column < AbstractMysqlAdapter::Column
        def adapter
          PerconaMigratorAdapter
        end
      end

      extend Forwardable

      ADAPTER_NAME = 'Percona'.freeze

      def_delegators :mysql_adapter, :last_inserted_id, :each_hash

      def initialize(connection, _logger, connection_options, _config)
        super
        @visitor = BindSubstitution.new(self)
        @mysql_adapter = connection_options[:mysql_adapter]
      end

      def exec_delete(sql, name, binds)
        execute(to_sql(sql, binds), name)
        @connection.affected_rows
      end
      alias :exec_update :exec_delete

      def exec_insert(sql, name, binds)
        execute(to_sql(sql, binds), name)
      end

      def exec_query(sql, name = 'SQL', _binds = [])
        result = execute(sql, name)
        ActiveRecord::Result.new(result.fields, result.to_a)
      end

      # Executes a SELECT query and returns an array of rows. Each row is an
      # array of field values.
      def select_rows(sql, name = nil)
        execute(sql, name).to_a
      end

      # Executes a SELECT query and returns an array of record hashes with the
      # column names as keys and column values as values.
      def select(sql, name = nil, binds = [])
        exec_query(sql, name, binds).to_a
      end

      # Returns true, as this adapter supports migrations
      def supports_migrations?
        true
      end

      def new_column(field, default, type, null, collation)
        Column.new(field, default, type, null, collation)
      end

      # Adds a new index to the table
      #
      # @param table_name [String, Symbol]
      # @param column_name [String, Symbol]
      # @param options [Hash] optional
      def add_index(table_name, column_name, options = {})
        index_name, index_type, index_columns, index_options = add_index_options(table_name, column_name, options)
        execute "ALTER TABLE #{quote_table_name(table_name)} ADD #{index_type} INDEX #{quote_column_name(index_name)} (#{index_columns})#{index_options}"
      end

      # Remove the given index from the table.
      #
      # @param table_name [String, Symbol]
      # @param options [Hash] optional
      def remove_index(table_name, options = {})
        index_name = index_name_for_remove(table_name, options)
        execute "ALTER TABLE #{quote_table_name(table_name)} DROP INDEX #{quote_column_name(index_name)}"
      end

      # Returns the MySQL error number from the exception. The
      # AbstractMysqlAdapter requires it to be implemented
      def error_number(_exception)
      end

      private

      attr_reader :mysql_adapter
    end
  end
end
