# name: discourse-data-explorer
# about: Interface for running analysis SQL queries on the live database
# version: 0.2
# authors: Riking
# url: https://github.com/discourse/discourse-data-explorer

enabled_site_setting :data_explorer_enabled
register_asset 'stylesheets/explorer.scss'

# route: /admin/plugins/explorer
add_admin_route 'explorer.title', 'explorer'

module ::DataExplorer
  def self.plugin_name
    'discourse-data-explorer'.freeze
  end

  def self.pstore_get(key)
    PluginStore.get(DataExplorer.plugin_name, key)
  end

  def self.pstore_set(key, value)
    PluginStore.set(DataExplorer.plugin_name, key, value)
  end

  def self.pstore_delete(key)
    PluginStore.remove(DataExplorer.plugin_name, key)
  end
end


after_initialize do

  module ::DataExplorer
    class Engine < ::Rails::Engine
      engine_name "data_explorer"
      isolate_namespace DataExplorer
    end

    class ValidationError < StandardError;
    end

    # Run a data explorer query on the currently connected database.
    #
    # @param [DataExplorer::Query] query the Query object to run
    # @param [Hash] params the colon-style query parameters to pass to AR
    # @param [Hash] opts hash of options
    #   explain - include a query plan in the result
    # @return [Hash]
    #   error - any exception that was raised in the execution. Check this
    #     first before looking at any other fields.
    #   pg_result - the PG::Result object
    #   duration_nanos - the query duration, in nanoseconds
    #   explain - the query
    def self.run_query(query, req_params={}, opts={})
      # Safety checks
      if query.sql =~ /;/
        err = DataExplorer::ValidationError.new(I18n.t('js.errors.explorer.no_semicolons'))
        return {error: err, duration_nanos: 0}
      end

      query_args = {}
      begin
        query_args = query.cast_params req_params
      rescue DataExplorer::ValidationError => e
        return {error: e, duration_nanos: 0}
      end

      # If we don't include this, then queries with a % sign in them fail
      # because AR thinks we want percent-based parametes
      query_args[:xxdummy] = 1

      time_start, time_end, explain, err, result = nil
      begin
        ActiveRecord::Base.connection.transaction do
          # Setting transaction to read only prevents shoot-in-foot actions like SELECT FOR UPDATE
          ActiveRecord::Base.exec_sql "SET TRANSACTION READ ONLY"
          # SQL comments are for the benefits of the slow queries log
          sql = <<SQL

/*
 * DataExplorer Query
 * Query: /admin/plugins/explorer?id=#{query.id}
 * Started by: #{opts[:current_user]}
 * :xxdummy
 */
WITH query AS (
#{query.sql}
) SELECT * FROM query
LIMIT #{opts[:limit] || 250}
SQL

          time_start = Time.now
          result = ActiveRecord::Base.exec_sql(sql, query_args)
          result.check # make sure it's done
          time_end = Time.now

          if opts[:explain]
            explain = ActiveRecord::Base.exec_sql("-- :xxdummy \nEXPLAIN #{query.sql}", query_args)
                        .map { |row| row["QUERY PLAN"] }.join "\n"
          end

          # All done. Issue a rollback anyways, just in case
          raise ActiveRecord::Rollback
        end
      rescue Exception => ex
        err = ex
        time_end = Time.now
      end

      {
        error: err,
        pg_result: result,
        duration_secs: time_end - time_start,
        explain: explain,
        params_full: query_args.tap {|h| h.delete :xxdummy}
      }
    end

    def self.sensitive_column_names
      %w(
#_IP_Addresses
topic_views.ip_address
users.ip_address
users.registration_ip_address
incoming_links.ip_address
topic_link_clicks.ip_address
user_histories.ip_address

#_Emails
email_tokens.email
users.email
invites.email
user_histories.email
email_logs.to_address
posts.raw_email
badge_posts.raw_email

#_Secret_Tokens
email_tokens.token
email_logs.reply_key
api_keys.key
site_settings.value

users.auth_token
users.password_hash
users.salt

#_Authentication_Info
user_open_ids.email
oauth2_user_infos.uid
oauth2_user_infos.email
facebook_user_infos.facebook_user_id
facebook_user_infos.email
twitter_user_infos.twitter_user_id
github_user_infos.github_user_id
single_sign_on_records.external_email
single_sign_on_records.external_id
google_user_infos.google_user_id
google_user_infos.email
      )
    end

    def self.schema
      # refer user to http://www.postgresql.org/docs/9.3/static/datatype.html
      @schema ||= begin
        results = ActiveRecord::Base.exec_sql <<SQL
select column_name, data_type, character_maximum_length, is_nullable, column_default, table_name
from INFORMATION_SCHEMA.COLUMNS where table_schema = 'public'
SQL
        by_table = {}
        # Massage the results into a nicer form
        results.each do |hash|
          full_col_name = "#{hash['table_name']}.#{hash['column_name']}"

          if hash['is_nullable'] == "YES"
            hash['is_nullable'] = true
          else
            hash.delete('is_nullable')
          end
          clen = hash.delete 'character_maximum_length'
          dt = hash['data_type']
          if dt == 'character varying'
            hash['data_type'] = "varchar(#{clen.to_i})"
          elsif dt == 'timestamp without time zone'
            hash['data_type'] = 'timestamp'
          elsif dt == 'double precision'
            hash['data_type'] = 'double'
          end
          default = hash['column_default']
          if default.nil? || default =~ /^nextval\(/
            hash.delete 'column_default'
          elsif default =~ /^'(.*)'::(character varying|text)/
            hash['column_default'] = $1
          end

          if sensitive_column_names.include? full_col_name
            hash['sensitive'] = true
          end
          if enum_info.include? full_col_name
            hash['enum'] = enum_info[full_col_name]
          end

          tname = hash.delete('table_name')
          by_table[tname] ||= []
          by_table[tname] << hash
        end

        # this works for now, but no big loss if the tables aren't quite sorted
        favored_order = %w(posts topics users categories badges groups notifications post_actions site_settings)
        sorted_by_table = {}
        favored_order.each do |tbl|
          sorted_by_table[tbl] = by_table[tbl]
        end
        by_table.keys.sort.each do |tbl|
          next if favored_order.include? tbl
          sorted_by_table[tbl] = by_table[tbl]
        end
        sorted_by_table
      end
    end


    def self.enums
      @enums ||= {
        :'category_groups.permission_type' => CategoryGroup.permission_types,
        :'directory_items.period_type' => DirectoryItem.period_types,
        :'groups.alias_level' => Group::ALIAS_LEVELS,
        :'groups.id' => Group::AUTO_GROUPS,
        :'notifications.notification_type' => Notification.types,
        :'posts.cook_method' => Post.cook_methods,
        :'posts.hidden_reason_id' => Post.hidden_reasons,
        :'posts.post_type' => Post.types,
        :'post_actions.post_action_type_id' => PostActionType.types,
        :'post_action_types.id' => PostActionType.types,
        :'queued_posts.state' => QueuedPost.states,
        :'site_settings.data_type' => SiteSetting.types,
        :'topic_users.notification_level' => TopicUser.notification_levels,
        :'topic_users.notifications_reason_id' => TopicUser.notification_reasons,
        :'user_histories.action' => UserHistory.actions,
        :'users.trust_level' => TrustLevel.levels,
      }.with_indifferent_access
    end

    def self.enum_info
      @enum_info ||= begin
        enum_info = {}
        enums.map do |key,enum|
          # https://stackoverflow.com/questions/10874356/reverse-a-hash-in-ruby
          enum_info[key] = Hash[enum.to_a.map(&:reverse)]
        end
        enum_info
      end
    end
  end

  # Reimplement a couple ActiveRecord methods, but use PluginStore for storage instead
  class DataExplorer::Query
    attr_accessor :id, :name, :description, :sql

    def initialize
      @name = 'Unnamed Query'
      @description = 'Enter a description here'
      @sql = 'SELECT 1'
    end

    def slug
      s = Slug.for(name)
      s = "query-#{id}" unless s.present?
      s
    end

    def params
      @params ||= DataExplorer::Parameter.create_from_sql(sql)
    end

    def check_params!
      DataExplorer::Parameter.create_from_sql(sql, strict: true)
      nil
    end

    def cast_params(input_params)
      result = {}.with_indifferent_access
      self.params.each do |pobj|
        result[pobj.identifier] = pobj.cast_to_ruby input_params[pobj.identifier]
      end
      result
    end

    # saving/loading functions
    # May want to extract this into a library or something for plugins to use?
    def self.alloc_id
      DistributedMutex.synchronize('data-explorer_query-id') do
        max_id = DataExplorer.pstore_get("q:_id")
        max_id = 1 unless max_id
        DataExplorer.pstore_set("q:_id", max_id + 1)
        max_id
      end
    end

    def self.from_hash(h)
      query = DataExplorer::Query.new
      [:name, :description, :sql].each do |sym|
        query.send("#{sym}=", h[sym]) if h[sym]
      end
      if h[:id]
        query.id = h[:id].to_i
      end
      query
    end

    def to_hash
      {
        id: @id,
        name: @name,
        description: @description,
        sql: @sql,
      }
    end

    def self.find(id, opts={})
      hash = DataExplorer.pstore_get("q:#{id}")
      unless hash
        return DataExplorer::Query.new if opts[:ignore_deleted]
        raise Discourse::NotFound
      end
      from_hash hash
    end

    def save
      check_params!
      unless @id && @id > 0
        @id = self.class.alloc_id
      end
      DataExplorer.pstore_set "q:#{id}", to_hash
    end

    def destroy
      DataExplorer.pstore_delete "q:#{id}"
    end

    def read_attribute_for_serialization(attr)
      self.send(attr)
    end

    def self.all
      PluginStoreRow.where(plugin_name: DataExplorer.plugin_name)
        .where("key LIKE 'q:%'")
        .where("key != 'q:_id'")
        .map do |psr|
        DataExplorer::Query.from_hash PluginStore.cast_value(psr.type_name, psr.value)
      end
    end
  end

  class DataExplorer::Parameter
    attr_accessor :identifier, :type, :default, :nullable

    def initialize(identifier, type, default, nullable)
      raise DataExplorer::ValidationError.new('Parameter declaration error - identifier is missing') unless identifier
      raise DataExplorer::ValidationError.new('Parameter declaration error - type is missing') unless type
      # process aliases
      type = type.to_sym
      if DataExplorer::Parameter.type_aliases[type]
        type = DataExplorer::Parameter.type_aliases[type]
      end
      raise DataExplorer::ValidationError.new("Parameter declaration error - unknown type #{type}") unless DataExplorer::Parameter.types[type]

      @identifier = identifier
      @type = type
      @default = default
      @nullable = nullable
      begin
        cast_to_ruby default unless default.blank?
      rescue DataExplorer::ValidationError
        raise DataExplorer::ValidationError.new("Parameter declaration error - the default value is not a valid #{type}")
      end
    end

    def to_hash
      {
        identifier: @identifier,
        type: @type,
        default: @default,
        nullable: @nullable,
      }
    end

    def self.types
      @types ||= Enum.new(
        # Normal types
        :int, :bigint, :boolean, :string, :date, :time, :datetime, :double,
        # Selection help
        :user_id, :post_id, :topic_id, :category_id, :group_id, :badge_id,
        # Arrays
        :int_list, :string_list, :user_list
      )
    end

    def self.type_aliases
      @type_aliases ||= {
        integer: :int,
        text: :string,
        timestamp: :datetime,
      }
    end

    def cast_to_ruby(string)
      string = @default unless string

      if string.blank?
        if @nullable
          return nil
        else
          raise DataExplorer::ValidationError.new("Missing parameter #{identifier} of type #{type}")
        end
      end
      if string.downcase == '#null'
        return nil
      end

      def invalid_format(string, msg=nil)
        if msg
          raise DataExplorer::ValidationError.new("'#{string}' is an invalid #{type} - #{msg}")
        else
          raise DataExplorer::ValidationError.new("'#{string}' is an invalid value for #{type}")
        end
      end

      value = nil

      case @type
        when :int
          value = string.to_i
          invalid_format string, 'Too large' unless Fixnum === value
        when :bigint
          value = string.to_i
        when :boolean
          value = !!(string =~ /t|true|y|yes|1/i)
        when :string
          value = string
        when :time
          begin
            value = Time.parse string
          rescue ArgumentError => e
            invalid_format string, e.message
          end
        when :date
          begin
            value = Date.parse string
          rescue ArgumentError => e
            invalid_format string, e.message
          end
        when :datetime
          begin
            value = DateTime.parse string
          rescue ArgumentError => e
            invalid_format string, e.message
          end
        when :double
          value = string.to_f
        when :category_id
          if string =~ /(.*)\/(.*)/
            parent_name = $1
            child_name = $2
            parent = Category.query_parent_category(parent_name)
            invalid_format string, "Could not find category named #{parent_name}" unless parent
            object = Category.query_category(child_name, parent)
            invalid_format string, "Could not find subcategory of #{parent_name} named #{child_name}" unless object
          else
            object = Category.where(id: string.to_i).first || Category.where(slug: string).first || Category.where(name: string).first
            invalid_format string, "Could not find category named #{string}" unless object
          end
          value = object.id
        when :user_id, :post_id, :topic_id, :group_id, :badge_id
          if string.gsub(/[ _]/, '') =~ /^-?\d+$/
            clazz_name = (/^(.*)_id$/.match(type.to_s)[1].classify.to_sym)
            begin
              Object.const_get(clazz_name).find(string.gsub(/[ _]/, '').to_i)
              value = pkey
            rescue ActiveRecord::RecordNotFound
              invalid_format string, "The specified #{clazz_name} was not found"
            end
          elsif type == :user_id
            begin
              object = User.find_by_username_or_email(string)
              value = object.id
            rescue ActiveRecord::RecordNotFound
              invalid_format string, "The user named #{string} was not found"
            end
          elsif type == :post_id
            if string =~ /(\d+)\/(\d+)(\?u=.*)?$/
              object = Post.with_deleted.find_by(topic_id: $1, post_number: $2)
              invalid_format string, "The post at topic:#{$1} post_number:#{$2} was not found" unless object
              value = object.id
            end
          elsif type == :topic_id
            if string =~ /\/t\/[^\/]+\/(\d+)/
              begin
                object = Topic.with_deleted.find($1)
                value = object.id
              rescue ActiveRecord::RecordNotFound
                invalid_format string, "The topic with id #{$1} was not found"
              end
            end
          elsif type == :group_id
            object = Group.where(name: string).first
            invalid_format string, "The group named #{string} was not found" unless object
            value = object.id
          else
            invalid_format string
          end
        when :int_list
          value = string.split(',').map {|s| s.downcase == '#null' ? nil : s.to_i }
          invalid_format string, "can't be empty" if value.length == 0
        when :string_list
          value = string.split(',').map {|s| s.downcase == '#null' ? nil : s }
          invalid_format string, "can't be empty" if value.length == 0
        when :user_list
          value = string.split(',').map {|s| User.find_by_username_or_email(s) }
          invalid_format string, "can't be empty" if value.length == 0
        else
          raise TypeError.new('unknown parameter type??? should not get here')
      end

      value
    end

    def self.create_from_sql(sql, opts={})
      in_params = false
      ret_params = []
      sql.split("\n").find do |line|
        if in_params
          # -- (ident) :(ident) (= (ident))?

          if line =~ /^\s*--\s*([a-zA-Z_ ]+)\s*:([a-z_]+)\s*(?:=\s+(.*)\s*)?$/
            type = $1
            ident = $2
            default = $3
            nullable = false
            if type =~ /^(null)?(.*?)(null)?$/i
              if $1 or $3
                nullable = true
              end
              type = $2
            end
            type = type.strip

            begin
              ret_params << DataExplorer::Parameter.new(ident, type, default, nullable)
            rescue
              if opts[:strict]
                raise
              end
            end

            false
          elsif line =~ /^\s+$/
            false
          else
            true
          end

        else
          if line =~ /^\s*--\s*\[params\]\s*$/
            in_params = true
          end
          false
        end
      end
      return ret_params
    end
  end

  require_dependency 'application_controller'
  class DataExplorer::QueryController < ::ApplicationController
    requires_plugin DataExplorer.plugin_name

    before_filter :check_enabled

    def check_enabled
      raise Discourse::NotFound unless SiteSetting.data_explorer_enabled?
    end

    def index
      # guardian.ensure_can_use_data_explorer!
      queries = DataExplorer::Query.all
      render_serialized queries, DataExplorer::QuerySerializer, root: 'queries'
    end

    skip_before_filter :check_xhr, only: [:show]
    def show
      check_xhr unless params[:export]

      query = DataExplorer::Query.find(params[:id].to_i)

      if params[:export]
        response.headers['Content-Disposition'] = "attachment; filename=#{query.slug}.dcquery.json"
        response.sending_file = true
      end

      # guardian.ensure_can_see! query
      render_serialized query, DataExplorer::QuerySerializer, root: 'query'
    end

    def create
      # guardian.ensure_can_create_explorer_query!

      query = DataExplorer::Query.from_hash params.require(:query)
      query.id = nil # json import will assign an id, which is wrong
      query.save

      render_serialized query, DataExplorer::QuerySerializer, root: 'query'
    end

    def update
      query = DataExplorer::Query.find(params[:id].to_i, ignore_deleted: true)
      hash = params.require(:query)

      # Undeleting
      unless query.id
        if hash[:id]
          query.id = hash[:id].to_i
        else
          raise Discourse::NotFound
        end
      end

      [:name, :sql, :description].each do |sym|
        query.send("#{sym}=", hash[sym]) if hash[sym]
      end

      query.check_params!
      query.save

      render_serialized query, DataExplorer::QuerySerializer, root: 'query'
    rescue DataExplorer::ValidationError => e
      render_json_error e.message
    end

    def destroy
      query = DataExplorer::Query.find(params[:id].to_i)
      query.destroy

      render json: {success: true, errors: []}
    end

    def schema
      schema_version = ActiveRecord::Base.exec_sql("SELECT max(version) AS tag FROM schema_migrations").first['tag']
      if stale?(public: true, etag: schema_version)
        render json: DataExplorer.schema
      end
    end

    skip_before_filter :check_xhr, only: [:run]
    # Return value:
    # success - true/false. if false, inspect the errors value.
    # errors - array of strings.
    # params - hash. Echo of the query parameters as executed.
    # duration - float. Time to execute the query, in milliseconds, to 1 decimal place.
    # columns - array of strings. Titles of the returned columns, in order.
    # explain - string. (Optional - pass explain=true in the request) Postgres query plan, UNIX newlines.
    # rows - array of array of strings. Results of the query. In the same order as 'columns'.
    def run
      check_xhr unless params[:download]
      query = DataExplorer::Query.find(params[:id].to_i)
      if params[:download]
        response.headers['Content-Disposition'] =
          "attachment; filename=#{query.slug}@#{Slug.for(Discourse.current_hostname, 'discourse')}-#{Date.today}.dcqresult.json"
        response.sending_file = true
      end

      query_params = MultiJson.load(params[:params])

      opts = {current_user: current_user.username}
      opts[:explain] = true if params[:explain] == "true"
      opts[:limit] = params[:limit].to_i if params[:limit]

      result = DataExplorer.run_query(query, query_params, opts)

      if result[:error]
        err = result[:error]

        # Pretty printing logic
        err_class = err.class
        err_msg = err.message
        if err.is_a? ActiveRecord::StatementInvalid
          err_class = err.original_exception.class
          err_msg.gsub!("#{err_class}:", '')
        else
          err_msg = "#{err_class}: #{err_msg}"
        end

        render json: {
                 success: false,
                 errors: [err_msg]
               }
      else
        pg_result = result[:pg_result]
        cols = pg_result.fields
        json = {
          success: true,
          errors: [],
          duration: (result[:duration_secs].to_f * 1000).round(1),
          params: query_params,
          columns: cols,
        }
        json[:explain] = result[:explain] if opts[:explain]
        # TODO - special serialization
        # This is dead code in the client right now
        # if cols.any? { |col_name| special_serialization? col_name }
        #   json[:relations] = DataExplorer.add_extra_data(pg_result)
        # end

        json[:rows] = pg_result.values

        render json: json
      end
    end
  end

  class DataExplorer::QuerySerializer < ActiveModel::Serializer
    attributes :id, :sql, :name, :description, :param_info

    def param_info
      object.params.map(&:to_hash) rescue nil
    end
  end

  DataExplorer::Engine.routes.draw do
    root to: "query#index"
    get 'schema' => "query#schema"
    get 'queries' => "query#index"
    post 'queries' => "query#create"
    get 'queries/:id' => "query#show"
    put 'queries/:id' => "query#update"
    delete 'queries/:id' => "query#destroy"
    post 'queries/:id/run' => "query#run"
  end

  Discourse::Application.routes.append do
    mount ::DataExplorer::Engine, at: '/admin/plugins/explorer', constraints: AdminConstraint.new
  end

end

