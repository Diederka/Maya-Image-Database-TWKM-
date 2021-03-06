#!/usr/bin/env ruby

# load debugger, .env and KOR
require 'pry'
require 'dotenv'
Dotenv.load
require "#{ENV['KOR_ROOT']}/config/environment"
# ---

def exif_for(path)
  output = `#{ENV['EXIFTOOL']} -j "#{path}"`
  data = JSON.parse(output)[0]
  if data['FileName'] == 'image.jpg'
    data.delete 'FileName'
  end
  data
rescue JSON::ParserError => e
  p e
  {}
end

def read_cache
  puts 'reading EXIF cache ...'
  results = {}
  Dir["#{ENV['EXIF_CACHE']}/*.json"].each do |f|
    id = f.split('/').last.split('.').first.to_i
    results[id] = JSON.load(File.read f)
  end
  results
end

def fill_cache
  scope = Entity.media.includes(:medium)
  pb = Kor.progress_bar 'parsing exif', scope.count
  scope.find_each do |entity|
    cache_file = "#{ENV['EXIF_CACHE']}/#{entity.id}.json"
    unless File.exists?(cache_file)
      path = entity.medium.path(:original)
      data = exif_for(path)
      File.open cache_file, 'w' do |f|
        f.write(JSON.pretty_generate data)
      end
    end
    pb.increment
  end
end

fill_cache
data = read_cache
# binding.pry

puts 'matching EXIF data to media ...'
Entity.media.includes(:medium).each do |entity|
  file_name = 
    entity.dataset['file_name'].presence ||
    entity.medium.image.original_filename
  exif = data[entity.id]

  # this holds the changes to be applied to this entity's dataset
  new_dataset = {}

  # do this for all images
  if exif # but only if we found any exif data
    mapping = {
      'ColorSpaceData' => 'color_space',
      'FileName' => 'file_name',
      'xResolution' => 'maximum_optical_resolution',
      'ImageWidth' => 'image_width',
      'ExifImageWidth' => 'image_width',
      'ImageHeight' => 'image_height',
      'ExifImageHeight' => 'image_height',
      'Make' => 'digital_camera_manufacturer',
      'Model' => 'digital_camera_model_name'
    }
    mapping.each do |from, to|
      if exif[from].present? && !entity.dataset[to].present? && !new_dataset[to].present?
        new_dataset[to] = exif[from]
      end
    end
  end

  # do this only for images starting with 'MET_', even if there was no exif
  # data, but in this case, the values should override preexisting ones
  if file_name.match?(/^MET_/)
    mapping = {
      'rights_holder' => 'Public Domain',
      'publisher' => 'Metropolitan Museum of Art',
      'contributor' => 'Maya Image Archive'
    }
    mapping.each do |field, value|
      if entity.dataset[field] != value
        new_dataset[field] = value
      end
    end
  end

  # do this only for images NOT starting with 'MET_', 'KHM_', 'NG_' or 'PAU_'
  if exif # but only if there is exif data
    if !file_name.match?(/^(KHM|NG|PAU)_/)
      mapping = {
        'Copyright' => 'rights_holder',
        'CreationDate' => 'date_time_created'
      }
      mapping.each do |from, to|
        if exif[from].present? && !entity.dataset[to].present? && !new_dataset[to].present?
          new_dataset[to] = exif[from]
        end
      end
    end
  end

  # we ensure that the best file_name we have is used in for the dataset field
  # 'file_name' if that isn't set already
  if !entity.dataset['file_name'].present? && !new_dataset['file_name'].present?
    #binding.pry
    new_dataset['file_name'] = file_name
  end

  unless new_dataset.empty?
    puts "entity #{entity.id}: applying new dataset values #{new_dataset.inspect}"

    # uncomment these lines to write the changes to the db
    # entity.dataset.merge!(new_dataset)
    # entity.update_column :attachment, entity.attachment
  end
end
