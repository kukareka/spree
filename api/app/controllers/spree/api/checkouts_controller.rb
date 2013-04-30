module Spree
  module Api
    class CheckoutsController < Spree::Api::BaseController
      before_filter :load_order, :only => [:update, :next]
      before_filter :associate_user, :only => :update

      include Spree::Core::ControllerHelpers::Auth
      include Spree::Core::ControllerHelpers::Order

      def create
        authorize! :create, Order
        @order = Order.build_from_api(current_api_user, nested_params)
        respond_with(@order, :default_template => 'spree/api/orders/show', :status => 201)
      end

      def next
        @order.next!
        respond_with(@order, :default_template => 'spree/api/orders/show', :status => 200)
      rescue StateMachine::InvalidTransition
        respond_with(@order, :default_template => 'spree/api/orders/could_not_transition', :status => 422)
      end

      def update
        user_id = object_params.delete(:user_id)
        if @order.update_attributes(object_params)
          # TODO: Replace with better code when we switch to strong_parameters
          # Also remove above user_id stripping
          if current_api_user.has_spree_role?("admin") && user_id.present?
            @order.associate_user!(Spree.user_class.find(user_id))
          end
          return if after_update_attributes
          state_callback(:after) if @order.next
          respond_with(@order, :default_template => 'spree/api/orders/show')
        else
          invalid_resource!(@order)
        end
      end

      private

        def object_params
          # For payment step, filter order parameters to produce the expected nested attributes for a single payment and its source, discarding attributes for payment methods other than the one selected
          # respond_to check is necessary due to issue described in #2910
          if @order.has_checkout_step?("payment") && @order.payment?
            if params[:payment_source].present? && source_params = params.delete(:payment_source)[params[:order][:payments_attributes].first[:payment_method_id].underscore]
              params[:order][:payments_attributes].first[:source_attributes] = source_params
            end
            if params[:order].present? && params[:order][:payments_attributes]
              params[:order][:payments_attributes].first[:amount] = @order.total
            end
          end
          params[:order] || {}
        end

        def nested_params
          map_nested_attributes_keys Order, params[:order] || {}
        end

        # Should be overriden if you have areas of your checkout that don't match
        # up to a step within checkout_steps, such as a registration step
        def skip_state_validation?
          false
        end

        def load_order
          @order = Spree::Order.find_by_number!(params[:id])
          raise_insufficient_quantity and return if @order.insufficient_stock_lines.present?
          @order.state = params[:state] if params[:state]
          state_callback(:before)
        end

        def current_currency
          Spree::Config[:currency]
        end

        def ip_address
          ''
        end

        def raise_insufficient_quantity
          respond_with(@order, :default_template => 'spree/api/orders/insufficient_quantity')
        end

        def state_callback(before_or_after = :before)
          method_name = :"#{before_or_after}_#{@order.state}"
          send(method_name) if respond_to?(method_name, true)
        end

        def before_address
          @order.bill_address ||= Address.default
          @order.ship_address ||= Address.default
        end

        def before_delivery
          return if params[:order].present?
          @order.create_proposed_shipments
        end

        def before_payment
          @order.payments.destroy_all if request.put?
        end

        def next!(options={})
          if @order.valid? && @order.next
            render 'spree/api/orders/show', :status => options[:status] || 200
          else
            render 'spree/api/orders/could_not_transition', :status => 422
          end
        end

        def after_update_attributes
          if object_params && object_params[:coupon_code].present?
            coupon_result = Spree::Promo::CouponApplicator.new(@order).apply
            if !coupon_result[:coupon_applied?]
              @coupon_message = coupon_result[:error]
              respond_with(@order, :default_template => 'spree/api/orders/could_not_apply_coupon')
              return true
            end
          end
          false
        end
    end
  end
end
