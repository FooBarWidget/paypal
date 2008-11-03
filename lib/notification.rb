require 'net/http'
require 'net/https'
require 'cgi'
require 'money'
require 'active_support'

module Paypal
  # Parser and handler for incoming instant payment notifications from Paypal.
  # The example shows a typical handler in a Rails application. Note that this
  # is an example, please read the Paypal API documentation for all the details
  # on creating a safe payment controller.
  #
  # Example
  #  
  #   class BackendController < ApplicationController
  #     def paypal_ipn
  #       notify = Paypal::Notification.new(request.raw_post)
  #       order = Order.find(notify.item_id)
  #       
  #       # Verify this IPN with Paypal.
  #       if notify.acknowledge
  #         # Paypal said this IPN is legit.
  #         begin
  #           if notify.complete? && order.total == notify.amount
  #             begin
  #               order.status = 'success'
  #               shop.ship(order)
  #               order.save!
  #             rescue => e
  #               order.status = 'failed'
  #               order.save!
  #               raise
  #             end
  #           else
  #             logger.error("We received a payment notification, but the " <<
  #                          "payment doesn't seem to be complete. Please " <<
  #                          "investigate. Transaction ID #{notify.transaction_id}.")
  #           end
  #       else
  #         # Paypal said this IPN is not correct.
  #         # ... log possible hacking attempt here ...
  #       end
  #       
  #       render :nothing => true
  #     end
  #   end
  class Notification
    CA_CERT_FILE = File.expand_path(File.join(File.dirname(__FILE__), "..", "misc", "verisign.pem"))
    
    # The parsed Paypal IPN data parameters.
    attr_accessor :params
    # The raw Paypal IPN data that was received.
    attr_accessor :raw

    # Overwrite this url. It points to the Paypal sandbox by default.
    # 
    # Example:
    #   Paypal::Notification.ipn_url = "https://www.paypal.com/cgi-bin/webscr"
    cattr_accessor :ipn_url
    @@ipn_url = 'https://www.sandbox.paypal.com/cgi-bin/webscr'
    
    cattr_accessor :ca_cert_file
    @@ca_cert_file = CA_CERT_FILE

    # Creates a new Paypal::Notification object. As the first argument,
    # pass the raw POST data that you've received from Paypal.
    #
    # In a Rails application this looks something like this:
    # 
    #   def paypal_ipn
    #     paypal = Paypal::Notification.new(request.raw_post)
    #     ...
    #   end
    def initialize(post)
      empty!
      parse(post)
    end
    
    # Returns the status of this transaction. May be "Completed", "Failed",
    # "Reversed" or "Pending". See the Paypal IPN documentation for more
    # information about IPN statuses.
    def status
      params['payment_status']
    end
    
    # Checks whether this Paypal transaction is completed. That is, as opposed
    # to being failed, reversed or pending. See the Paypal IPN documentation for
    # more information about IPN statuses.
    def complete?
      status == "Completed"
    end
    
    # Checks whether this Paypal transaction is pending.
    def pending?
      status == "Pending"
    end
    
    def receiver_email
      params['receiver_email']
    end
    
    # When was this payment received by the client. 
    # sometimes it can happen that we get the notification much later. 
    # One possible scenario is that our web application was down. In this case paypal tries several 
    # times an hour to inform us about the notification
    def received_at
      Time.parse(params['payment_date'])
    end

    # Id of this transaction (paypal number)
    def transaction_id
      params['txn_id']
    end

    # What type of transaction are we dealing with? 
    #  "cart" "send_money" "web_accept" are possible here. 
    def type
      params['txn_type']
    end

    # The amount of money that we've received, in X.2 decimal.
    def gross
      params['mc_gross']
    end

    # the markup paypal charges for the transaction
    def fee
      params['mc_fee']
    end

    # What currency have we been dealing with
    def currency
      params['mc_currency']
    end
    
    # This is the item number which we submitted to paypal 
    def item_id
      params['item_number']
    end

    # This is the invocie which you passed to paypal 
    def invoice
      params['invoice']
    end
    
    # This is the invocie which you passed to paypal 
    def test?
      params['test_ipn'] == '1'
    end

    # This is the custom field which you passed to paypal 
    def invoice
      params['custom']
    end
    
    def gross_cents
      (gross.to_f * 100.0).round
    end

    # This combines the gross and currency and returns a proper Money object. 
    # this requires the money library located at http://dist.leetsoft.com/api/money
    def amount
      return Money.new(gross_cents, currency) rescue ArgumentError
      return Money.new(gross_cents) # maybe you have an own money object which doesn't take a currency?
    end
    
    # reset the notification. 
    def empty!
      @params  = Hash.new
      @raw     = ""      
    end

    # Acknowledge the transaction to paypal. This method has to be called after a new 
    # IPN arrives. Paypal will verify that all the information we received are
    # correct and will return a ok or a fail. 
    # 
    # Example:
    # 
    #   def paypal_ipn
    #     notify = PaypalNotification.new(request.raw_post)
    #
    #     if notify.acknowledge 
    #       ... process order ... if notify.complete?
    #     else
    #       ... log possible hacking attempt ...
    #     end
    #   end
    def acknowledge      
      payload = raw
      
      uri = URI.parse(self.class.ipn_url)
      request_path = "#{uri.path}?cmd=_notify-validate"
      
      request = Net::HTTP::Post.new(request_path)
      request['Content-Length'] = "#{payload.size}"
      request['User-Agent']     = "paypal-ruby -- http://rubyforge.org/projects/paypal/"

      http = Net::HTTP.new(uri.host, uri.port)

      if uri.scheme == "https"
        http.use_ssl = true
        if self.class.ca_cert_file
          http.verify_mode = OpenSSL::SSL::VERIFY_PEER
          if http.respond_to?(:enable_post_connection_check)
            # http://www.ruby-lang.org/en/news/2007/10/04/net-https-vulnerability/
            http.enable_post_connection_check = true
          end
          http.ca_file = self.class.ca_cert_file
        else
          http.verify_mode = OpenSSL::SSL::VERIFY_NONE
        end
      end

      request = http.request(request, payload)
      
      raise StandardError.new("Faulty paypal result: #{request.body}") unless ["VERIFIED", "INVALID"].include?(request.body)
      
      request.body == "VERIFIED"
    end

    private
    
    # Take the posted data and move the relevant data into a hash
    def parse(post)
      @raw = post
      for line in post.split('&')    
        key, value = *line.scan( %r{^(\w+)\=(.*)$} ).flatten
        params[key] = CGI.unescape(value)
      end
    end

  end
end
