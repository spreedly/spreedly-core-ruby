module SpreedlyCore
  # Abstract class for all the different spreedly transactions
  class Transaction < Base
    attr_reader(:amount, :on_test_gateway, :created_at, :updated_at, :currency_code,
                :succeeded, :token, :message, :transaction_type, :gateway_token,
                :response, :signed, :state, :checkout_url, 
                :order_id, :description, :merchant_name_descriptor, :merchant_location_descriptor)
    alias :succeeded? :succeeded

    # Breaks enacapsulation a bit, but allow subclasses to register the 'transaction_type'
    # they handle.
    def self.handles(transaction_type)
      @@transaction_type_to_class ||= {}
      @@transaction_type_to_class[transaction_type] = self
    end

    # Lookup the transaction by its token. Returns the correct subclass
    def self.find(token)
      return nil if token.nil?
      verify_get("/transactions/#{token}.xml", :has_key => "transaction") do |response|
        attrs = response.parsed_response["transaction"]
        klass = @@transaction_type_to_class[attrs["transaction_type"]] || self
        klass.new(attrs).tap do |transaction|
          transaction.verified!
        end
      end
    end

    def initialize(attrs={})
      super
      if(valid_signature?)
        verified!
      end
    end

    def verified!
      @verified = true
    end

    def verified?
      @verified
    end

    def pending?
      state == "pending"
    end

    def valid_signature?
      return false unless signed
      fields = signed["fields"]
      data = fields.collect do |field|
        self.instance_variable_get("@#{field}")
      end.join("|")
      (OpenSSL::HMAC.hexdigest(OpenSSL::Digest::Digest.new(signed["algorithm"], SpreedlyCore::Base.secret, data)) == signed["signature"])
    end
  end

  class RetainTransaction < Transaction
    handles "RetainPaymentMethod"
    attr_reader :payment_method

    def initialize(attrs={})
      @payment_method = PaymentMethod.new(attrs.delete("payment_method") || {})
      super(attrs)
    end
  end

  class RedactTransaction < Transaction
    handles "RedactPaymentMethod"
    attr_reader :payment_method

    def initialize(attrs={})
      @payment_method = PaymentMethod.new(attrs.delete("payment_method") || {})
      super(attrs)
    end
  end

  module NullifiableTransaction
    # Void is used to cancel out authorizations and, with some gateways, to
    # cancel actual payment transactions within the first 24 hours
    def void(ip_address=nil)
      body = {:transaction => {:ip => ip_address}}
      self.class.verify_post("/transactions/#{token}/void.xml",
                             :body => body, :has_key => "transaction") do |response|
        VoidedTransaction.new(response.parsed_response["transaction"])
      end
    end

    # Credit amount. If amount is nil, then credit the entire previous purchase
    # or captured amount
    def credit(amount=nil, ip_address=nil)
      body = if amount.nil?
               {:ip => ip_address}
             else
               {:transaction => {:amount => amount, :ip => ip_address}}
             end
      self.class.verify_post("/transactions/#{token}/credit.xml",
                             :body => body, :has_key => "transaction") do |response|
        CreditTransaction.new(response.parsed_response["transaction"])
      end
    end
  end

  module HasIpAddress
    attr_reader :ip
  end

  class AuthorizeTransaction < Transaction
    include HasIpAddress

    handles "Authorization"
    attr_reader :payment_method

    def initialize(attrs={})
      @payment_method = PaymentMethod.new(attrs.delete("payment_method") || {})
      @response = Response.new(attrs.delete("response") || {})
      super(attrs)
    end

    # Capture the previously authorized payment. If the amount is nil, the
    # captured amount will the amount from the original authorization. Some
    # gateways support partial captures which can be done by specifiying an
    # amount
    def capture(amount=nil, ip_address=nil)
      body = if amount.nil?
               {}
             else
               {:transaction => {:amount => amount, :ip => ip_address}}
             end
      self.class.verify_post("/transactions/#{token}/capture.xml",
                            :body => body, :has_key => "transaction") do |response|
        CaptureTransaction.new(response.parsed_response["transaction"])
      end
    end
  end

  class PurchaseTransaction < Transaction
    include NullifiableTransaction
    include HasIpAddress

    handles "Purchase"
    attr_reader :payment_method

    def initialize(attrs={})
      @payment_method = PaymentMethod.new(attrs.delete("payment_method") || {})
      @response = Response.new(attrs.delete("response") || {})
      super(attrs)
    end
  end

  class CaptureTransaction < Transaction
    include NullifiableTransaction
    include HasIpAddress

    handles "Capture"
    attr_reader :reference_token
  end

  class VoidedTransaction < Transaction
    include HasIpAddress

    handles "Void"
    attr_reader :reference_token
  end

  class CreditTransaction < Transaction
    include HasIpAddress

    handles "Credit"
    attr_reader :reference_token
  end

  class AddPaymentMethodTransaction < Transaction
    include HasIpAddress

    handles "AddPaymentMethod"
    attr_reader :payment_method
  end

end
