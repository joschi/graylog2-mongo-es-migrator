%w{logger yaml rubygems bundler mongo tire multi_json rest-client}.each { |f| require f}

log = Logger.new(STDOUT)
log.level = Logger::INFO

config_file = 'config/migrator.yml'

if ARGV.size > 0
  config_file = ARGV[0]
end

log.info "Loading configuration from #{config_file}"
config = YAML::load_file config_file

(puts <<-INSTALL; exit 1) unless (RestClient.get(config['es_url']) rescue false)

[ERROR] You don't appear to have ElasticSearch installed. Please install and launch it with the following commands:

# wget http://github.com/downloads/elasticsearch/elasticsearch/elasticsearch-0.18.5.tar.gz
# tar -xzf elasticsearch-0.18.5.tar.gz
# elasticsearch-0.18.5/bin/elasticsearch -f
INSTALL

Tire.configure {
  url config['es_url']

  if config.has_key? 'es_debug_log'
    logger config['es_debug_log']
  end
}

Tire.index config['es_index_name'] do
  if config['es_delete_index']
    log.info "Deleting index #{config['es_index_name']}"
    delete
  end

  unless exists?
    log.info "Creating index #{config['es_index_name']}"

    create :mappings => {
        :message => {
            :properties => {
                :message => {:type => 'string', :index => 'analyzed'},
                :full_message => {:type => 'string', :index => 'analyzed'},
                :created_at => {:type => 'double'},
            },
            :dynamic_templates => [
                {
                    :store_generic => {
                        :match => '*',
                        :mapping => {:index => 'not_analyzed'}
                    }
                }
            ]
        }
    }
  end

  unless exists?
    log.error "Couldn't create index #{config['es_index_name']}!"
    exit(1)
  end
end


mongo = Mongo::Connection.new(config['mongo_host'], config['mongo_port']).db(config['mongo_db'])

if config['mongo_use_auth']
  mongo.authenticate(config['mongo_username'], config['mongo_password'])
end

collection = mongo.collection 'messages'

mongo_message_count = collection.count

log.info "#{mongo_message_count} messages in MongoDB collection 'message'"

log.info 'Starting to copy messages'
current_message = 0

collection.find.each do |message|
  log.debug "Processing message with _id #{message.__id__}"

  # Remove implicit _id field of MongoDB
  message.delete '_id'

  # Set message type (to match index from above)
  message['type'] = 'message'

  Tire.index config['es_index_name'] do
    store message
  end

  current_message += 1
  if current_message % 1000 == 0
    log.info "Copied #{current_message} messages"
  end
end

Tire.index config['es_index_name'] do
  refresh
end

response = RestClient.get "#{config['es_url']}/#{config['es_index_name']}/message/_count"
response_json = MultiJson.decode response.body
es_message_count = response_json[:count]

log.info "#{es_message_count} messages in ElasticSearch index 'message'"

if mongo_message_count > es_message_count
  log.error "There are #{mongo_message_count} messages in MongoDB but only #{es_message_count} messages in ElasticSearch"
  exit 1
end