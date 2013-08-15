require 'net/http'
require 'uri'
require 'json'
require 'hashie'
require 'singleton'
require 'logger'
require 'awesome_print'
require 'awesome_print/core_ext/logger' #For some reason we get an error indicating that the method 'ap' is private unless we load this specifically
require 'json/add/regexp'
require 'pact/matchers'

AwesomePrint.defaults = {
  indent: -2,
  plain: true,
  index: false
}

module Pact
  module Consumer

    class InteractionList
      include Singleton

      attr_reader :interactions

      def initialize
        @interactions = []
        @matched_interactions = []
      end

      def add interactions
        @interactions << interactions
      end

      def register_matched interaction
        @matched_interactions << interaction
      end

      def all_matched?
        @interactions - @matched_interactions == []
      end

      def interaction_diffs
        @interactions - @matched_interactions
      end

      def clear
        @interactions.clear
      end
    end

    class StartupPoll

      def initialize name, logger
        @name = name
        @logger = logger
      end

      def match? env
        env['REQUEST_PATH'] == '/index.html' &&
          env['REQUEST_METHOD'] == 'GET'
      end

      def respond env
        @logger.info "#{@name} started up"
        [200, {}, ['Started up fine']]
      end
    end

    class CapybaraIdentify

      def initialize name, logger
        @name = name
        @logger = logger
      end

      def match? env
        env["PATH_INFO"] == "/__identify__"
      end

      def respond env
        [200, {}, [object_id.to_s]]
      end
    end

    class InteractionDelete

      def initialize name, logger
        @name = name
        @logger = logger
      end

      def match? env
        env['REQUEST_PATH'] == '/interactions' &&
          env['REQUEST_METHOD'] == 'DELETE'
      end

      def respond env
        InteractionList.instance.clear
        @logger.info "Cleared interactions"
        [200, {}, ['Deleted interactions']]
      end
    end

    class InteractionPost

      def initialize name, logger
        @name = name
        @logger = logger
      end

      def match? env
        env['REQUEST_PATH'] == '/interactions' &&
          env['REQUEST_METHOD'] == 'POST'
      end

      def respond env
        interactions = Hashie::Mash.new(JSON.load(env['rack.input'].string))
        InteractionList.instance.add interactions
        @logger.info "Added interaction to #{@name}"
        @logger.ap interactions
        [200, {}, ['Added interactions']]
      end
    end

    module RequestExtractor

      REQUEST_KEYS = Hashie::Mash.new({
        'REQUEST_METHOD' => :method,
        'REQUEST_PATH' => :path,
        'QUERY_STRING' => :query,
        'rack.input' => :body
      })

      def request_from env
        request = env.inject({}) do |memo, (k, v)|
          request_key = REQUEST_KEYS[k]
        memo[request_key] = v if request_key
        memo
        end

        mashed_request = Hashie::Mash.new request
        mashed_request[:headers] = headers_from env
        body_string = mashed_request[:body].read

        if (body_string.empty?)
          mashed_request.delete :body
        else
          body_is_json = mashed_request[:headers]['Content-Type'] =~ /json/
          mashed_request[:body] =  body_is_json ? JSON.parse(body_string) : body_string
        end
        mashed_request[:method] = mashed_request[:method].downcase
        mashed_request
      end

      def headers_from env
        headers = env.reject{ |key, value| !(key.start_with?("HTTP") || key == 'CONTENT_TYPE')}
        headers.inject({}) do | hash, header |
          hash[standardise_header(header.first)] = header.last
          hash
        end
      end

      def standardise_header header
        header.gsub(/^HTTP_/, '').split("_").collect{|word| word[0] + word[1..-1].downcase}.join("-")
      end
    end

    class InteractionReplay
      include Pact::Matchers
      include RequestExtractor

      def initialize name, logger
        @name = name
        @logger = logger
      end

      def match? env
        true # default handler
      end

      def respond env
        find_response request_from(env)
      end

      private

      def find_response raw_request
        actual_request = Request::Actual.from_hash(raw_request)
        @logger.info "#{@name} received request"
        @logger.ap actual_request.as_json
        candidates = []
        matching_interactions = InteractionList.instance.interactions.select do |interaction|
          expected_request = Request::Expected.from_hash(interaction.request)
          candidates << expected_request if expected_request.matches_route? actual_request
          expected_request.match actual_request
        end
        if matching_interactions.size > 1
          @logger.info "Multiple interactions found on #{@name}:"
          @logger.ap matching_interactions
          raise 'Multiple interactions found!'
        end
        if matching_interactions.empty?
          handle_unrecognised_request(actual_request, candidates)
        else
          response = response_from(matching_interactions.first.response)
          InteractionList.instance.register_matched matching_interactions.first
          @logger.info "Found matching response on #{@name}:"
          @logger.ap response
          response
        end
      end

      def handle_unrecognised_request request, candidates
        @logger.ap "No interaction found on #{@name} for request"
        @logger.ap 'Interaction diffs for that route:'
        interaction_diff = candidates.map do |candidate|
          diff(candidate.as_json, request.as_json)
        end.to_a
        @logger.ap(interaction_diff)
        response = {message: "No interaction found for #{request.path}", interaction_diff:  interaction_diff}
        [500, {'Content-Type' => 'application/json'}, [response.to_json]]
      end

      def response_from response
        [response.status, (response.headers || {}).to_hash, [render_body(response.body)]]
      end

      def render_body body
        return '' unless body
        body.kind_of?(String) ? body.force_encoding('utf-8') : body.to_json
      end

      def logger_info_ap msg
        @logger.info msg
      end
    end

    class VerificationGet
      def initialize name, logger
        @name = name
        @logger = logger
      end

      def match? env
        env['REQUEST_PATH'] == '/verify' &&
          env['REQUEST_METHOD'] == 'GET'
      end

      def respond env
        if InteractionList.instance.all_matched?
          @logger.info "Veryifying - interactions matched"
          [200, {}, ['Interactions matched']]
        else
          @logger.warn "Verifying - actual interactions do not match expected interactions. Missing interactions:"
          @logger.ap InteractionList.instance.interaction_diffs, :warn
          [500, {}, ["Actual interactions do not match expected interactions"]]
        end
      end
    end

    class MockService

      def initialize options = {}
        options = {log_file: STDOUT}.merge options
        @logger = Logger.new options[:log_file]
        @name = options.fetch(:name, "MockService")
        @handlers = [
          StartupPoll.new(@name, @logger),
          CapybaraIdentify.new(@name, @logger),
          VerificationGet.new(@name, @logger),
          InteractionPost.new(@name, @logger),
          InteractionDelete.new(@name, @logger),
          InteractionReplay.new(@name, @logger)
        ]
      end

      def to_s
        "#{@name} #{super.to_s}"
      end

      def call env
        response = []
        begin
          relevant_handler = @handlers.detect { |handler| handler.match? env }
          response = relevant_handler.respond env
        rescue Exception => e
          @logger.ap 'Error ocurred in mock service:'
          @logger.ap e
          @logger.ap e.backtrace
          raise e
        end
        response
      end

    end
  end
end
