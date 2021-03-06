#<< toaster/utils/*
#<< toaster/core/script

class Builder

	# requirements
	fs = require 'fs'
	path = require 'path'
	cs = require "coffee-script"
	uglify = require("uglify-js").uglify
	uglify_parser = require("uglify-js").parser

	Script = toaster.core.Script
	FnUtil = toaster.utils.FnUtil
	FsUtil = toaster.utils.FsUtil
	ArrayUtil = toaster.utils.ArrayUtil
	StringUtil = toaster.utils.StringUtil



	_toaster_helper: """
		__t = ( ns )->
			curr = null
			parts = [].concat = ns.split "."
			for part, index in parts
				if curr == null
					curr = eval part
					continue
				else
					unless curr[ part ]?
						curr = curr[ part ] = {}
					else
						curr = curr[ part ]
			curr
	"""

	_include_tmpl: "document.write('<scri'+'pt src=\"%SRC%\"></scr'+'ipt>')"



	constructor:(@toaster, @cli, @config)->
		@vendors = @config.vendors

		@bare = @config.bare
		@packaging = @config.packaging
		@expose = @config.expose
		@minify = @config.minify
		@exclude = [].concat( @config.exclude )

		@httpfolder = @config.httpfolder
		@release = @config.release
		@debug = @config.debug

		@init()
		@watch() if @cli.argv.w

	init:()->
		# initializes buffer array to keep all tracked files
		@files = @config.files
		for folder in @config.src_folders

			# search for all *.coffee files inside src folder
			result = FsUtil.find folder.path, /.coffee/

			# folder path and alias
			fpath = folder.path
			falias = folder.alias

			# collects every files into Script instances
			for file in result

				include = true
				for item in @exclude

					include &= !(new RegExp( item ).test file)

				if include
					s = new Script @, fpath, file, falias, @cli
					@files.push s


	build:( header_code = "", footer_code = "" )=>
		# namespaces
		namespaces = @build_namespaces()

		# prepare helper
		if @packaging
			helper = cs.compile @_toaster_helper, {bare:true}
		else
			helper = ""

		# prepare vendors
		vendors = @merge_vendors()

		# prepare release contents
		contents = []
		contents.push vendors if vendors isnt ""
		contents.push helper if @packaging
		contents.push namespaces if @packaging
		contents.push header_code if header_code isnt ""
		contents.push @compile()
		contents.push footer_code if header_code isnt ""
		contents = contents.join '\n'

		# uglifying
		if @minify
			ast = uglify_parser.parse contents
			ast = uglify.ast_mangle ast
			ast = uglify.ast_squeeze ast
			contents = uglify.gen_code ast

		# write release file
		fs.writeFileSync @release, contents

		# notify user through cli
		now = new Date()
		now = "#{now.getHours()}:#{now.getMinutes()}:#{now.getSeconds()}"
		log "#{'Compiled'.bold} #{@release} @ #{now}".green

		# compiling for debug
		if @cli.argv.d && @debug?
			files = @compile_for_debug()

			# saving boot loader
			for f, i in files
				include = "#{@httpfolder}/toaster/#{f}"
				tmpl = @_include_tmpl.replace "%SRC%", include
				files[i] = tmpl

			# prepare boot loader contents
			contents = []
			contents.push vendors if vendors isnt ""
			contents.push helper if @packaging
			contents.push namespaces if @packaging
			contents.push header_code if header_code isnt ""
			contents.push (files.join "\n")
			contents.push footer_code if header_code isnt ""
			contents = contents.join '\n'

			# write boot-loader file
			fs.writeFileSync @debug, contents

			# notify user through cli
			now = new Date()
			now = "#{now.getHours()}:#{now.getMinutes()}:#{now.getSeconds()}"
			log "#{'Compiled'.bold} #{@debug} @ #{now}".green

	# get all root namespaces
	build_namespaces:( after_build_namespaces )->
		namespaces = ""

		for folder in @config.src_folders
			if folder.alias?
				namespaces += @build_namespaces_declaration folder.alias
			else
				subfolders = FsUtil.ls_folders folder.path

				for subfolder in subfolders
					name = subfolder.match /[^\/]+$/m
					namespaces += @build_namespaces_declaration name

		return namespaces


	build_namespaces_declaration:( name )=>
		declaration = ""
		declaration += "var #{name} = " if @packaging
		declaration += "#{@expose}.#{name} = " if @expose?
		declaration += "{};\n" if declaration.length

		return declaration


	watch:()->
		# loops through all source folders
		for src in @config.src_folders

			# and watch them entirely
			FsUtil.watch_folder src.path, /.coffee$/, FnUtil.proxy (src, info)=>

				# skip all watching notifications
				return if info.action == "watching" 

				# skipe all folder creation
				return if info.type == "folder" and info.action == "created"

				# folder path and alias
				ipath = info.path
				fpath = src.path
				falias = src.alias || ""

				# Titleize the type for use in the log messages bellow
				type = StringUtil.titleize info.type

				# relative filepath
				relative_path = info.path.replace "#{fpath}/", "#{falias}/"
				if relative_path.substr( 0, 1 ) == "/"
					relative_path = relative_path.substr 1

				# switch over created, deleted, updated and watching
				switch info.action

					# when a new file is created
					when "created"

						# initiate file and adds it to the array
						if info.type == "file"
							# toaster/core/script
							s = new Script @, fpath, ipath, falias, @cli
							@files.push s

						# cli msg
						msg = "#{('New ' + info.type + ' created').bold.cyan}"
						log "#{msg} #{info.path.green}"

					# when a file is deleted
					when "deleted"

						# removes files from array
						file = ArrayUtil.find @files, relative_path, "filepath"
						return if file is null

						@files.splice file.index, 1

						# cli msg
						msg = "#{(type + ' deleted, stop watching').bold.red}"
						log "#{msg} #{info.path.red}"

					# when a file is updated
					when "updated"

						# updates file information
						file = ArrayUtil.find @files, relative_path, "filepath"
						file.item.getinfo()

						# cli msg
						msg = "#{(type + ' changed').bold.cyan}"
						log "#{msg} #{info.path.cyan}"

					# when a file starts being watched
					# when "watching"
					# 	msg = "#{('Watching ' + info.type + ':').bold.cyan}"
						# log "#{msg} #{info.path.cyan}"

				# rebuilds modules unless notificiation is 'watching'
				@build()

				after_watch?()
			, src



	compile:()->
		# validating syntax
		for file in @files
			try
				cs.compile file.raw
			# if there's some error
			catch err

				# catches and shows it, and abort the compilation
				msg = err.message.replace '"', '\\"'
				msg = "#{msg.white} at file: " + "#{file.filepath}".bold.red
				error msg
				return null

		# otherwise move ahead, and expands all dependencies wild-cards
		file.expand_dependencies() for file in @files

		# reordering files
		@reorder()

		# merging everything
		output = (file.raw for file in @files).join "\n"

		# compiling
		output = cs.compile output, {bare: @bare}

	compile_for_debug:()->
		release_path = @release.split("/").slice(0, -1).join "/"
		release_path += "/toaster"

		# cleaning previous/existent structure
		FsUtil.rmdir_rf release_path if path.existsSync release_path

		# creating new structre from scratch
		FsUtil.mkdir_p release_path

		# initializing empty array of filepaths
		files = []

		# loop through all ordered files
		for file, index in @files

			# computing releative filepath (replacing .coffee by .js)
			relative_path = file.filepath.replace ".coffee", ".js"

			# computing absolute filepath
			absolute_path = "#{release_path}/#{relative_path}"

			# extracts its folder path
			folder_path = absolute_path.split('/').slice(0,-1).join "/"

			# create container folder if it doesnt exist yet
			FsUtil.mkdir_p folder_path if !path.existsSync folder_path

			# writing file
			try
				fs.writeFileSync absolute_path, cs.compile file.raw, {bare:@bare}
			catch err
				msg = err.message.replace '"', '\\"'
				console.log "MSG:::: " + msg
				msg = "#{msg.white} at file: " + "#{file.filepath}".bold.red
				error msg
				continue

			# adds to the files buffer
			files.push relative_path

		# returns all filepaths
		return files



	missing = {}
	reorder: (cycling = false) ->
		# log "Module.reorder"

		# if cycling is true or @missing is null, initializes empty array
		# for holding missing dependencies
		# 
		# cycling means the redorder method is being called recursively,
		# no other methods call it with cycling = true
		@missing = {} if cycling is false

		# looping through all files
		for file, i in @files

			# if theres no dependencies, go to next file
			continue if !file.dependencies.length && !file.baseclasses.length
			
			# otherwise loop thourgh all file dependencies
			for filepath, index in file.dependencies

				# search for dependency
				dependency = ArrayUtil.find @files, filepath, "filepath"
				dependency_index = dependency.index if dependency?

				# continue if the dependency was already initialized
				continue if dependency_index < i && dependency?

				# if it's found
				if dependency?

					# if there's some circular dependency loop
					if ArrayUtil.has dependency.item.dependencies, file.filepath

						# remove it from the dependencies
						file.dependencies.splice index, 1

						# then prints a warning msg and continue
						warn "Circular dependency found between ".yellow +
						     filepath.grey.bold + " and ".yellow +
						     file.filepath.grey.bold
						
						continue

					# otherwise if no circular dependency is found, reorder
					# the specific dependency and run reorder recursively
					# until everything is beautiful
					else
						@files.splice index, 0, dependency.item
						@files.splice dependency.index + 1, 1
						@reorder true
						break

				# otherwise if the dependency is not found
				else if @missing[filepath] != true
					
					# then add it to the @missing hash (so it will be ignored
					# until reordering finishes)
					@missing[filepath] = true

					# move it to the end of the dependencies array (avoiding
					# it from being touched again)
					file.dependencies.push filepath
					file.dependencies.splice index, 1

					# ..and finally prints a warning msg
					warn "#{'Dependency'.yellow} #{filepath.bold.grey} " +
						 "#{'not found for file'.yellow} " +
						 file.filepath.grey.bold

			# validate if all base classes was properly imported
			file_index = ArrayUtil.find @files, file.filepath, "filepath"
			file_index = file_index.index

			for bc in file.baseclasses
				found = ArrayUtil.find @files, bc, "classname"
				not_found = (found == null) || (found.index > file_index)

				if not_found && !@missing[bc]
					@missing[bc] = true
					warn "Base class ".yellow +
						 "#{bc} ".bold.grey +
						 "not found for class ".yellow +
						 "#{file.classname} ".bold.grey +
						 "in file ".yellow +
						 file.filepath.bold.grey



	merge_vendors:()=>
		buffer = []
		for vendor in @vendors
			if path.existsSync vendor
				buffer.push fs.readFileSync vendor, 'utf-8'
			else
				warn "Vendor not found at ".white + vendor.yellow.bold

		return buffer.join "\n"