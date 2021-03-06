
# Sorry, nokogiri is required for the canonicalization stuff :-(
require 'nokogiri'
require 'openssl'
require File.join(File.dirname(__FILE__), 'transbank', 'transbank_oneclick_response')

module ActiveMerchant #:nodoc:
  module Billing #:nodoc:

    #
    # = Transbank Oneclick Gateway
    #
    # Only supported in Chile by Transbank. Based on a SOAP interface,
    # this library provides access to the methods used to initiate a
    # payment and tigger storage of the user's card details.
    #
    # Transbank currently only allow new cardholder details to be provided
    # on their hosted web pages. These always take the client through their
    # authorizing banks authentication process, similar to 3D Secure.
    #
    # Once details have been secured, purchases and refunds can be made
    # using the provided token.
    #
    # In effect, this gateway has a lot in common with PayPal Express.
    #
    # Method names for non-standard operations, such as inscription, are
    # based on the operation names provided by Transbank.
    #
    # == Bugs
    #
    # Transbank have several bugs with their service which they are unwilling
    # to fix at present. They don't seem to care either, probably due to
    # their complete monopoly of credit card sales in Chile. When developing
    # please take the following into account:
    #
    #  * The `:return_url` in `init_inscription` cannot contain the & character.
    #    The service will return an error if this is the case. This makes it
    #    especially difficult to provide your own variables in the return url.
    #  * You cannot redirect the user to transbank using a GET request, you must
    #    use a form with a POST.
    #  * The `username` to be provided during inscription *must* be unique!
    #    Adding a new payment method with the same username will provide the
    #    same token and *overwrite* any previous method.
    #  * To add to the complexity, the username will be shown in the payment
    #    screen, so it is good idea to include the real name and a random code,
    #    for example `Sam Lown (12syzq)`.
    #  * The `order_id` must be numerical. This library will assign a number for
    #    you based on the current time with miliseconds which has a pretty slim
    #    chance of collisions.
    #
    # == Using
    #
    # Configure the gateway with the self-signed certificate you provided to
    # transbank along with your private key:
    #
    #    gateway = ActiveMerchant::Billing::TransbankOneclickGateway.new(
    #      :certificate => File.read(Rails.root.join('config', 'oneclick.crt')),
    #      :private_key => File.read(Rails.root.join('config', 'oneclick.key'))
    #    )
    #
    # A subscribe request must first be performed to receive a token used to send
    # the user's browser to Transbanks card entry and authentication screens:
    #
    #    response = gatway.init_inscription(
    #      :username   => 'someuser',
    #      :email      => 'client@email.com',
    #      :return_url => 'https://XYZ.com'
    #    )
    #
    # Both :username and :email are required. They will be shown as a confirmation
    # to the user when they enter their card details. Internally the :username
    # is required for each purchase and must be the same for the transaction
    # to be accepted, as such this library tries to handle this automatically.
    #
    # The inscription response will include a token. This must be used with the
    # gateway's `#redirect_url` method to show the user a form prepared to
    # POST the 'token' under the parameter "TBK_TOKEN". It's probably a good idea
    # to use javascript to do submit the form automatically:
    #
    #    <% form_tag @gateway.redirect_url do %>
    #      <%= hidden_field_tag :TBK_TOKEN, @response.token %>
    #    <% end %>
    #
    # Assuming the process is successful, Transbank will POST the user back to your
    # `return_url` with the parameter `TBK_TOKEN` in the body. Send this with the same
    # username to the `#finish_inscription` method to finalize the new card process:
    #
    #    response = gateway.finish_inscription(params[:TBK_TOKEN], :username => "Sam Lown")
    #    if response.success?
    #      # do something with response.token
    #    else
    #      # do something with response.message
    #    end
    #
    # To ensure the username is the same for both init and finish inscription,
    # the recommended solution is to store the value in the user's session. It'll
    # be automatically included in the token for future use, so you can safely
    # forget about it.
    #
    # With the new inscription token, you can start to make payments:
    #
    #    response = gateway.purchase(400000, token)
    #
    # The payment in this case is for 4000 CLP in cents.
    #
    # To perform refunds, use the authorization property from the purchase
    # response:
    #
    #    gateway.refund(response.authorization)
    #
    # The authorization field is actually the :order_id that was either
    # provided in the purchase request or generated by the module.
    #
    #
    class TransbankOneclickGateway < Gateway
      if respond_to?(:class_attribute)
        class_attribute :test_redirect_url
        class_attribute :live_redirect_url
      else
        class_inheritable_accessor :test_redirect_url
        class_inheritable_accessor :live_redirect_url
      end

      self.test_url = 'https://webpay3gint.transbank.cl/webpayserver/wswebpay/OneClickPaymentService'
      self.live_url = 'https://webpay3g.transbank.cl/webpayserver/wswebpay/OneClickPaymentService'

      self.test_redirect_url = "https://webpay3gint.transbank.cl/webpayserver/bp_inscription.cgi"
      self.live_redirect_url = "https://webpay3g.transbank.cl/webpayserver/bp_inscription.cgi"

      self.supported_countries = ['CL']

      self.default_currency = 'CLP'

      # The card types supported by the payment gateway
      self.supported_cardtypes = [:visa, :master, :american_express, :diners_club, :magna]

      # The homepage URL of the gateway
      self.homepage_url = 'http://www.webpay.cl'

      # The name of the gateway
      self.display_name = 'Transbank Oneclick'


      # Prepare the XML namespace and algorithm constants
      SOAP_NAMESPACE      = 'http://schemas.xmlsoap.org/soap/envelope/'
      TRANSBANK_NAMESPACE = 'http://webservices.webpayserver.transbank.com/'
      WSSE_NAMESPACE      = 'http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd'

      WSU_NAMESPACE       = 'http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd'
      EC_NAMESPACE        = 'http://www.w3.org/2001/10/xml-exc-c14n#'
      DS_NAMESPACE        = 'http://www.w3.org/2000/09/xmldsig#'

      C14N_ALGORITHM      = 'http://www.w3.org/2001/10/xml-exc-c14n#'
      DIGEST_ALGORITHM    = 'http://www.w3.org/2000/09/xmldsig#sha1'
      SIGNATURE_ALGORITHM = 'http://www.w3.org/2000/09/xmldsig#rsa-sha1'


      # Response Code Texts According the Transbank Oneclick manual.
      RESPONSE_TEXTS = {
        '0'   => 'Success',
        '-1'  => 'Declined',
        '-2'  => 'Declined',
        '-3'  => 'Declined',
        '-4'  => 'Declined',
        '-5'  => 'Declined',
        '-6'  => 'Declined',
        '-7'  => 'Declined',
        '-8'  => 'Declined',
        '-97' => 'Maximum daily number of payments exceeded',
        '-98' => 'Maximum payment amount exceeded',
        '-99' => 'Maximum daily payment amount exceeded',
      }

      # Creates a new instance
      #
      # Only the private key and certificate are required.
      #
      def initialize(options = {})
        requires!(options, :private_key, :certificate)
        super
      end

      #### Subscription Handling


      # Start a new subscription process.
      #
      # Assuming successful, a Response object will be provided
      #
      def init_inscription(options = {})
        requires!(options, :username, :email, :return_url)

        data = {}
        add_return_url(data, options[:return_url])
        add_customer_details(data, options)

        commit :init_inscription, data
      end

      def finish_inscription(token, options = {})
        requires!(options, :username)

        data = {}
        add_token(data, token)
        add_customer_details(data, options)

        commit :finish_inscription, data
      end

      def remove_user(token)
        token, username = split_token(token)
        options[:username] = username

        data = {}
        add_token(data, token)
        add_customer_details(data, options)

        commit :remove_user, data
      end


      #### Regular Active Merchant Methods

      # If no order_id is provided in the options, it will be
      # generated automatically.
      def purchase(money, token, options = {})
        token, username = split_token(token)

        data = {}

        options[:username] = username
        add_customer_details(data, options)
        add_token(data, token)

        add_amount(data, money)
        add_order(data, options[:order_id])

        commit :authorize, data
      end

      # Void or "reversa" as Transbank call it can only be called 24
      # hours after a purchase operation.
      # Its main purpose is to cancel an operation if something
      # went wrong during the purchase process.
      def void(authorization, options = {})
        data = {}
        add_order(data, authorization)

        commit :reverse, data
      end

      # This needs to be a public method until transbank support a proper
      # redirect with GET rather than requiring a POST.
      def redirect_url
        test? ? test_redirect_url : live_redirect_url
      end

      private

      def split_token(token)
        token, username = token.split("|")
        [token, Base64.urlsafe_decode64(username)]
      end

      def build_token(token, username)
        [token, Base64.urlsafe_encode64(username)].join("|")
      end

      def add_amount(data, money)
        data[:amount] = amount(money).to_s
      end

      def add_order(data, order_id = nil)
        data[:order_id] = order_id.nil? ? Time.now.strftime('%Y%m%d%H%M%S%L') : order_id
      end

      def add_token(data, token)
        data[:token] = token
      end

      def add_return_url(data, url)
        data[:return_url] = url
      end

      def add_customer_details(data, options)
        data[:username] = options[:username]
        data[:email]    = options[:email] if options[:email]
      end


      # Init inscription data requires:
      #
      #   :username
      #   :email
      #   :return_url
      #
      def build_init_inscription_body(xml, data)
        xml['web'].initInscription('xmlns:web' => TRANSBANK_NAMESPACE) do
          xml_arg(xml, { email: data[:email], responseURL: data[:return_url], username: data[:username] })
        end
      end

      # Finish inscription request requires:
      #
      #   :token
      #
      def build_finish_inscription_body(xml, data)
        xml['web'].finishInscription('xmlns:web' => TRANSBANK_NAMESPACE) do
          xml_arg(xml, { token: data[:token] })
        end
      end

      # Remove the user from transbank, takes the fields:
      #
      #   :token    => Given when inscription created
      #   :username => Users human name, not necessarily login
      #
      def build_remove_user_body(xml, data)
        xml['web'].removeUser('xmlns:web' => TRANSBANK_NAMESPACE) do
          xml_arg(xml, { tbkUser: data[:token], username: data[:username] })
        end
      end

      # Request requires:
      #
      #   :username
      #   :amount
      #   :order_id
      #
      def build_authorize_body(xml, data)
        xml['web'].authorize('xmlns:web' => TRANSBANK_NAMESPACE) do
          xml_arg(xml, {
            amount: data[:amount],
            buyOrder: data[:order_id],
            tbkUser: data[:token],
            username: data[:username]
          })
        end
      end

      # Requires:
      #
      #  :order_id
      #
      def build_reverse_body(xml, data)
        xml['web'].reverse('xmlns:web' => TRANSBANK_NAMESPACE) do
          xml_arg(xml, { buyorder: data[:order_id] })
        end
      end

      def xml_arg(xml, params)
        xml.arg0 do
          params.each do |key, value|
            xml.parent.namespace = xml.parent.namespace_definitions.first
            xml.send key, value
          end
        end
      end

      # Return an OpenSSL X509 certificate ready to use
      def certificate
        @_certificate ||= OpenSSL::X509::Certificate.new(@options[:certificate])
      end

      # Provide the certificate issuer in RFC2253 format
      def certificate_issuer
        certificate.issuer.to_s.split(/\//).reject{|n| n.to_s.empty?}.join(',')
      end

      def private_key
        @_private_key ||= OpenSSL::PKey::RSA.new(@options[:private_key])
      end

      # The Transbank server public key and certificate
      def remote_certificate
        @_remote_cert ||= OpenSSL::X509::Certificate.new(
          File.read(File.dirname(__FILE__) + '/transbank/server.pem')
        )
      end

      def signature_for(text)
        Base64.strict_encode64(
          private_key.sign(OpenSSL::Digest::SHA1.new, text)
        )
      end

      def digest_for(text)
        OpenSSL::Digest::SHA1.new.base64digest(text)
      end

      # Build up a soap request envelope including the payload and basic structure.
      # Please use extreme caution when modifying this method. Canonicalization is
      # complicated and can be easily put off course.
      def build_soap_envelope
        xml = Nokogiri::XML::Builder.new do |xml|
          xml.Envelope('xmlns:soap' => SOAP_NAMESPACE, 'xmlns:web' => TRANSBANK_NAMESPACE, 'xmlns:wsse' => WSSE_NAMESPACE) do
            # Add soap namespace to root
            ns = xml.parent.namespace_definitions.find{|ns|ns.prefix=="soap"}
            xml.doc.root.namespace = ns

            # Add the header
            xml['soap'].Header do
              xml['wsse'].Security('soap:mustUnderstand' => '1', 'xmlns:wsu' => WSU_NAMESPACE, 'xmlns:ec' => EC_NAMESPACE, 'xmlns:ds' => DS_NAMESPACE) do
                xml['ds'].Signature(:Id => 'SIG-16') do |xml|

                  xml['ds'].SignedInfo do |xml|
                    xml['ds'].CanonicalizationMethod('Algorithm' => C14N_ALGORITHM) do
                      xml['ec'].InclusiveNamespaces('PrefixList' => "soap web")
                    end
                    xml['ds'].SignatureMethod('Algorithm' => SIGNATURE_ALGORITHM)
                    xml['ds'].Reference(:URI => '#id-body-1') do |xml|
                      xml['ds'].Transforms do
                        xml['ds'].Transform('Algorithm' => C14N_ALGORITHM) do
                          xml['ec'].InclusiveNamespaces('PrefixList' => "web")
                        end
                      end
                      xml['ds'].DigestMethod('Algorithm' => DIGEST_ALGORITHM)
                      xml['ds'].DigestValue '' # Digest placeholder
                    end
                  end

                  xml['ds'].SignatureValue '' # Signature placeholder

                  xml['ds'].KeyInfo(:Id => 'KI-1') do
                    xml['wsse'].SecurityTokenReference('wsu:Id' => 'STR-1') do
                      xml['ds'].X509Data do
                        xml['ds'].X509IssuerSerial do
                          xml['ds'].X509IssuerName   certificate_issuer
                          xml['ds'].X509SerialNumber certificate.serial
                        end
                      end
                    end
                  end # KeyInfo
                end # Signature
              end # Security
            end # Header

            # Add the actual payload
            xml['soap'].Body('wsu:Id' => 'id-body-1', 'xmlns:wsu' => WSU_NAMESPACE) do
              yield xml
            end
          end
        end
        xml
      end

      # Add the magical security signatures to the soap envelope so that it
      # is ready to send to the server.
      def add_soap_digital_signatures(xml)
        # To get round silly namespace issues and help canonicalization,
        # reload the doc
        doc = Nokogiri::XML.parse(xml.doc.to_xml)

        # Extract the Body and generate for digest
        body = doc.xpath('/soap:Envelope/soap:Body', 'soap' => SOAP_NAMESPACE).first()
        body = body.canonicalize(Nokogiri::XML::XML_C14N_EXCLUSIVE_1_0, ['web'])

        # Set the digest
        digest = doc.xpath('//ds:DigestValue', 'ds' => DS_NAMESPACE).first
        digest.content = digest_for(body)

        # Prepare the SignedInfo for the signature
        signed_info = doc.xpath('//ds:SignedInfo', 'ds' => DS_NAMESPACE).first
        canon = signed_info.canonicalize(Nokogiri::XML::XML_C14N_EXCLUSIVE_1_0, ['soap', 'web'])

        # Add the signature to the document
        signed_value = doc.xpath('//ds:SignatureValue', 'ds' => DS_NAMESPACE).first
        signed_value.content = signature_for(canon)

        doc.to_xml
      end

      def url
        test? ? test_url : live_url
      end

      def commit(method, data)
        xml = build_soap_envelope do |xml|
          send("build_#{method}_body", xml, data)
        end
        doc = add_soap_digital_signatures(xml)

        parse ssl_post(url, doc), data
      rescue ActiveMerchant::ResponseError => e
        parse e.response.body, data
      end

      # Parse the incoming SOAP response.
      def parse(xml, data)
        doc     = Nokogiri::XML.parse(xml)
        options = @options.merge(:test => test?)

        # Make sure that the digest is okay
        if valid_digest?(doc)
          params = body_to_params(doc)

          # Manually add the order_id as it is not provided by the server
          params['buyOrder'] ||= data[:order_id] if data.include?(:order_id)

          # Build a usable token with the username
          if params.include?('tbkUser')
            params['token'] = build_token(params['tbkUser'], data[:username])
          end

          TransbankOneclickResponse.new(params['success'], params['message'], params, options)
        else
          TransbankOneclickResponse.new(false, "Invalid response digest!")
        end
      end

      # Convert the body into a hash of params and try to determine if we were successful
      def body_to_params(doc)
        params = {}
        body = doc.xpath('/soap:Envelope/soap:Body', 'soap' => SOAP_NAMESPACE).first
        ret = body.xpath('//return').first
        if ret
          if ret.content =~ /true|false/
            # From commands: reverse, removeUser
            params['success'] = (ret.content == 'true')
          else
            # From commands: initInscription, finishInscription, authorize
            ret.children.each do |child|
              unless child.name.blank?
                params[child.name.to_s] = child.content
              end
            end
            params['message'] = RESPONSE_TEXTS[params['responseCode']]
            params['success'] = params['token'] ? true : (params['responseCode'] == "0")
          end
        else
          # Something is very wrong
          fault = body.xpath('//faultstring').first
          params['success'] = false
          params['message']   = fault ? fault.content : "Unknown fault"
        end
        params
      end

      def valid_digest?(doc)
        # If we have a Fault, don't check digest
        return true if doc.xpath('//soap:Fault', 'soap' => SOAP_NAMESPACE).first()

        # Do we have any special namespaces for canonicalization?
        ins = doc.xpath('//ds:Transform/ec:InclusiveNamespaces', 'ds' => DS_NAMESPACE, 'ec' => EC_NAMESPACE).first
        ns = ins ? ins.attr('PrefixList').to_s.split(/ /) : nil

        # Extract the Body and generate for digest
        body = doc.xpath('/soap:Envelope/soap:Body', 'soap' => SOAP_NAMESPACE).first()
        body = body.canonicalize(Nokogiri::XML::XML_C14N_EXCLUSIVE_1_0, ns)

        # Grab the digest
        digest = doc.xpath('//ds:DigestValue', 'ds' => DS_NAMESPACE).first

        digest.content == digest_for(body)
      end


      #### Force TLSv1

      # Get arround issues with the Transbank servers that respond with
      # timeouts and verification errors if a connection is attempted with
      # TLSv1.2, the standard in new release of OpenSSL.
      #
      # This is the procedure suggested by Nathaniel Talbot to override the
      # new_connection method used by PostsData.
      #
      #   https://groups.google.com/d/topic/activemerchant/SZgiVs6bUmI/discussion
      #

      class CrippledSslConnection < ActiveMerchant::Connection
        def configure_ssl(http)
          super(http)
          http.ssl_version = :TLSv1
          # The active_utils gem contains an out of date cacert.pem file.
          # Setting this to nil will the use the more up to date system
          # file.
          http.ca_file = nil
        end
      end

      #def new_connection(endpoint)
      #  CrippledSslConnection.new(endpoint)
      #end

      ####

    end
  end
end

