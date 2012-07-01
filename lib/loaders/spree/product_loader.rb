# Copyright:: (c) Autotelik Media Ltd 2010
# Author ::   Tom Statter
# Date ::     Aug 2010
# License::   MIT ?
#
# Details::   Specific over-rides/additions to support Spree Products
#
require 'loader_base'
require 'csv_loader'
require 'excel_loader'
require 'image_loader'

module DataShift

  module SpreeHelper

    class ProductLoader < LoaderBase

      include DataShift::CsvLoading
      include DataShift::ExcelLoading
      include DataShift::ImageLoading

      # depending on version get_product_class should return us right class, namespaced or not

      def initialize(product = nil)
        super( SpreeHelper::get_product_class(), product, :instance_methods => true  )

        @@image_klass ||= SpreeHelper::get_spree_class('Image')
        @@option_type_klass ||= SpreeHelper::get_spree_class('OptionType')
        @@option_value_klass ||= SpreeHelper::get_spree_class('OptionValue')
        @@property_klass ||= SpreeHelper::get_spree_class('Property')
        @@product_property_klass ||= SpreeHelper::get_spree_class('ProductProperty')
        @@taxonomy_klass ||= SpreeHelper::get_spree_class('Taxonomy')
        @@taxon_klass ||= SpreeHelper::get_spree_class('Taxon')
        @@variant_klass ||= SpreeHelper::get_spree_class('Variant')

        raise "Failed to create Product for loading" unless @load_object

        logger.debug "PRODUCT #{@load_object.inspect} MASTER: #{@load_object.master.inspect}"
      end


      # Over ride base class process with some Spree::Product specifics
      #
      # What process a value string from a column, assigning value(s) to correct association on Product.
      # Method map represents a column from a file and it's correlated Product association.
      # Value string which may contain multiple values for a collection (has_many) association.
      #
      def process()

        # Special cases for Products, generally where a simple one stage lookup won't suffice
        # otherwise simply use default processing from base class
        if(current_value && (@current_method_detail.operator?('variants') || @current_method_detail.operator?('option_types')) )

          add_options

        elsif(@current_method_detail.operator?('taxons') && current_value)

          add_taxons

        elsif(@current_method_detail.operator?('product_properties') && current_value)

          add_properties

        elsif(@current_method_detail.operator?('images') && current_value)

          add_images

        elsif(current_value && (@current_method_detail.operator?('count_on_hand') || @current_method_detail.operator?('on_hand')) )


          # Unless we can save here, in danger of count_on_hand getting wiped out.
          # If we set (on_hand or count_on_hand) on an unsaved object, during next subsequent save
          # looks like some validation code or something calls Variant.on_hand= with 0
          # If we save first, then our values seem to stick

          # TODO smart column ordering to ensure always valid - if we always make it very last column might not get wiped ?
          #
          save_if_new


          # Spree has some stock management stuff going on, so dont usually assign to column vut use
          # on_hand and on_hand=
          if(@load_object.variants.size > 0)

            if(current_value.to_s.include?(LoaderBase::multi_assoc_delim))

              #puts "DEBUG: COUNT_ON_HAND PER VARIANT",current_value.is_a?(String),

              # Check if we processed Option Types and assign count per option
              values = current_value.to_s.split(LoaderBase::multi_assoc_delim)

              if(@load_object.variants.size == values.size)
                @load_object.variants.each_with_index {|v, i| v.on_hand = values[i].to_i; v.save; }
              else
                puts "WARNING: Count on hand entries did not match number of Variants - None Set"
              end
            end

            # can only set count on hand on Product if no Variants exist, else model throws

          elsif(@load_object.variants.size == 0)
            if(current_value.to_s.include?(LoaderBase::multi_assoc_delim))
              puts "WARNING: Multiple count_on_hand values specified but no Variants/OptionTypes created"
              load_object.on_hand = current_value.to_s.split(LoaderBase::multi_assoc_delim).first.to_i
            else
              load_object.on_hand = current_value.to_i
            end
          end

        else
          super
        end
      end

      private



      # Special case for OptionTypes as it's two stage process
      # First add the possible option_types to Product, then we are able
      # to define Variants on those options values.
      #
      def add_options

        # TODO smart column ordering to ensure always valid by time we get to associations
        save_if_new

        option_types = get_each_assoc#current_value.split( LoaderBase::multi_assoc_delim )
        @ovs = []
        option_types.each do |ostr|
          oname, value_str = ostr.split(LoaderBase::name_value_delim)
          @current_ovs = []
          option_type = @@option_type_klass.find_by_name(oname)

          unless option_type
            option_type = @@option_type_klass.create( :name => oname, :presentation => oname.humanize)
            # TODO - dynamic creation should be an option

            unless option_type
              puts "WARNING: OptionType #{oname} NOT found and could not create - Not set Product"
              next
            end
            puts "Created missing OptionType #{option_type.inspect}"
          end

          # TODO - is include? very inefficient ??
          @load_object.option_types << option_type unless @load_object.option_types.include?(option_type)

          # Can be simply list of OptionTypes, some or all without values
          next unless(value_str)

          # Now get the value(s) for the option e.g red,blue,green for OptType 'colour'
          ovalues = value_str.split(',')

          # TODO .. benchmarking to find most efficient way to create these but ensure Product.variants list
          # populated .. currently need to call reload to ensure this (seems reqd for Spree 1/Rails 3, wasn't required b4
          ovalues.each_with_index do |ovname, i|
            ovname.strip!
            ov = @@option_value_klass.find_or_create_by_name_and_option_type_id(ovname, option_type.id)
            if ov
              @current_ovs << ov
            else
              puts "WARNING: Option #{ovname} NOT FOUND - No Variant created"
            end
          end
          @ovs << @current_ovs
          #puts "DEBUG Load Object now has Variants : #{@load_object.variants.inspect}"
          @load_object.reload unless @load_object.new_record?
          #puts "DEBUG Load Object now has Variants : #{@load_object.variants.inspect}"
        end


        @res = @ovs.shift.product(*@ovs)

        @res.each_with_index do |ovs, i|
          begin
            # This one line seems to works for 1.1.0 - 3.2 but not 1.0.0 - 3.1 ??
            if(SpreeHelper::version.to_f >= 1.1)
              variant = @load_object.variants.create( :sku => "#{@load_object.sku}_#{i}", :price => @load_object.price)
            else
              variant = @@variant_klass.create( :product => @load_object, :sku => "#{@load_object.sku}_#{i}", :price => @load_object.price, :available_on => @load_object.available_on)
              #if(variant.valid?)
              # variant.save
              # @load_object.variants << variant

              #else
              #puts "WARNING: For Option #{ovname} - Variant creation failed #{variant.errors.inspect}"
            end
            variant.option_values = ovs
          rescue =>  e
            puts "Failed to create a Variant for Product #{@load_object.name}"
            puts e.inspect
            # puts e.backtrace
          end

          logger.debug "Created New Variant: #{variant.inspect}"

        end
      end

      # Special case for Images
      # A list of paths to Images with a optional 'alt' value - supplied in form :
      #   path:alt|path2:alt2|path_3:alt3 etc
      #
      def add_images
        # TODO smart column ordering to ensure always valid by time we get to associations
        save_if_new

        images = get_each_assoc#current_value.split(LoaderBase::multi_assoc_delim)

        images.each do |image|

          img_path, alt_text = image.split(LoaderBase::name_value_delim)

          image = create_image(@@image_klass, img_path, @load_object, :alt => alt_text)
          logger.debug("Product assigned an Image : #{image.inspect}")
        end

      end


      # Special case for ProductProperties since it can have additional value applied.
      # A list of Properties with a optional Value - supplied in form :
      #   property_name:value|property_name|property_name:value
      #  Example :
      #  test_pp_002|test_pp_003:Example free value|yet_another_property

      def add_properties
        # TODO smart column ordering to ensure always valid by time we get to associations
        save_if_new

        property_list = get_each_assoc#current_value.split(LoaderBase::multi_assoc_delim)

        property_list.each do |pstr|

          # Special case, we know we lookup on name so operator is effectively the name to lookup
          find_by_name, find_by_value = get_find_operator_and_rest( pstr )

          raise "Cannot find Property via #{find_by_name} (with value #{find_by_value})" unless(find_by_name)

          property = @@property_klass.find_by_name(find_by_name)

          unless property
            property = @@property_klass.create( :name => find_by_name, :presentation => find_by_name.humanize)
            logger.info "Created New Property #{property.inspect}"
          end

          if(property)
            if(SpreeHelper::version.to_f >= 1.1)
              # Property now protected from mass assignment
              x = @@product_property_klass.new( :value => find_by_value )
              x.property = property
              x.save
              @load_object.product_properties << x
              logger.info "Created New ProductProperty #{x.inspect}"
            else
              @load_object.product_properties << @@product_property_klass.create( :property => property, :value => find_by_values)
            end
          else
            puts "WARNING: Property #{find_by_name} NOT found - Not set Product"
          end

        end

      end

      # Nested tree structure support ..
      # TAXON FORMAT
      # name|name>child>child|name

      def add_taxons
        # TODO smart column ordering to ensure always valid by time we get to associations
        save_if_new

        chain_list = get_each_assoc#current_value().split(LoaderBase::multi_assoc_delim)

        chain_list.each do |chain|

          name_list = chain.split(/\s*>\s*/)

          # manage per chain
          parent_taxonomy, parent, taxon = nil, nil, nil

          # Each chain can contain either a single Taxon, or the tree like structure parent>child>child
          taxons = name_list.collect do |name|

            #puts "DEBUG: NAME #{name.inspect}"
            begin
              taxon = @@taxon_klass.find_by_name( name )

              if(taxon)
                parent_taxonomy ||= taxon.taxonomy
              else
                parent_taxonomy ||= @@taxonomy_klass.find_or_create_by_name(name)

                taxon = @@taxon_klass.find_or_create_by_name_and_parent_id_and_taxonomy_id(name, parent && parent.id, parent_taxonomy.id)
              end
            rescue => e
              puts e.inspect
              puts "ERROR : Cannot assign Taxon ['#{taxon}'] to Product ['#{load_object.name}']"
              next
            end

            parent = taxon
            taxon
          end

          unique_list = taxons.compact.uniq - (@load_object.taxons || [])

          logger.debug("Product assigned to Taxons : #{unique_list.collect(&:name).inspect}")
          @load_object.taxons << unique_list unless(unique_list.empty?)
        end

      end

    end
  end
end