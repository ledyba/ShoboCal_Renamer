# -*- coding: utf-8 -*-

=begin
    ShoboCal_Renamer
    Copyright (C) 2011 PSI

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.
=end

require 'optparse'
require 'open-uri'
require 'rexml/document'
require 'scanf'
require 'rubygems'
require 'sqlite3'

FOLTIA_DB = "/server/data/foltia/foltia.sqlite"
FOLTIA_ENCODING="EUC-JP"
FOLTIA_EPG_SUBTITLE_MAX = 48

SHOBOCAL_DB_URL="http://cal.syoboi.jp/db.php?Command=TitleLookup&TID=%d&Fields=Title,SubTitles"

class DBHolder
	def initialize()
		@db = SQLite3::Database.new(FOLTIA_DB);
	end
	def getRaw
		return @db
	end
	def close
		@db.close
		@@obj = nil
	end
	def self.getInstance()
		unless defined?(@@obj)
			@@obj = DBHolder.new
		end
		return @@obj;
	end
end

class FileIndexRemover
	def initialize()
	end
	def remove(filename)
		DBHolder.getInstance.getRaw.execute("DELETE FROM foltia_m2pfiles WHERE m2pfilename = ?", filename.to_s)
	end
	
	def self.getInstance()
		unless defined?(@@obj)
			@@obj = FileIndexRemover.new
		end
		return @@obj;
	end
end

class EpgResolver
	def initialize()
		db = DBHolder.getInstance.getRaw
		@SubTitles = Hash.new();
		
		station_hash = Hash.new
		db.execute("select * from foltia_station") {|row|
			station_hash[row[0].to_i] = row[9].to_i
		}
		db.execute("select * from foltia_subtitle where tid=0") {|row|
			key = row[5].to_s+"-"+station_hash[row[2].to_i].to_s;
			subtitle = row[4].force_encoding(FOLTIA_ENCODING).encode('UTF-8').tr('a-zA-Z!?:;/\|,*"><','ａ-ｚＡ-Ｚ！？：；／￥｜，＊');
			@SubTitles[key] = subtitle;
		}
		@SubTitles.freeze
	end
	def getTitle(data, time, channel)
		return @SubTitles[data.to_s+time.to_s+"-"+channel.to_s];
	end

	def self.getInstance()
		unless defined?(@@obj)
			@@obj = EpgResolver.new
		end
		return @@obj;
	end
end

class Title
	def initialize(db, title_number)
		@SubTitles = Array.new;
		@TitleNumber = title_number
		uri = URI.parse(sprintf(SHOBOCAL_DB_URL,title_number));
		@Title = sub_titles = REXML::Document.new(uri.read).elements['TitleLookupResponse/TitleItems/TitleItem/Title'].get_text.to_s;
		sub_titles = REXML::Document.new(uri.read).elements['TitleLookupResponse/TitleItems/TitleItem/SubTitles'].get_text.to_s;
		sub_titles.each_line{|line|
			elm = line.scanf("*%d*%s")
			#FIXME: このやばいくらいに漂うバッドノウハウ感
			# ファイル名に使用できない文字を全角に変換しています。
			@SubTitles[elm[0]] = elm[1].tr('a-zA-Z!?:;/\|,*"><','ａ-ｚＡ-Ｚ！？：；／￥｜，＊')
		}
	end
	
	def getNumberOfSubTitles()
		return @SubTitles.size
	end
	def getTitle
		return @Title
	end
	def getSubTitle(num)
		return @SubTitles[num]
	end
end

class TitleResolver
	def initialize()
		@TitleBank = Hash.new
	end
	def check(title)
		unless @TitleBank.has_key? title
			@TitleBank[title] = Title.new(@DB, title)
		end
	end
	protected :check
	def getNumberOfSubTitles(title)
		check(title)
		return @TitleBank[title].getNumberOfSubTitles
	end
	def getTitleSet(title, num)
		check(title)
		return @TitleBank[title].getTitle(), @TitleBank[title].getSubTitle(num)
	end
	def getTitle(title)
		check(title)
		return @TitleBank[title].getTitle(num)
	end
	def getSubTitle(title, num)
		check(title)
		return @TitleBank[title].getSubTitle(num)
	end
	def self.getInstance()
		unless defined?(@@obj)
			@@obj = TitleResolver.new
		end
		return @@obj;
	end
end

class Formatter
	FormatPattern = /%(.*?)%/
	ReplacePattern = {
		"ext" => "(.+)",
		"channel" => "(?:-(\\d+))?",
	}
	def initialize(format_str)
		@idx_hash = Hash.new
		cnt = 0
		format_str_regexp = "^"+Regexp.escape(format_str)+"$"
		pat_str = format_str_regexp.gsub(FormatPattern){|str|
			@idx_hash[$1] = cnt
			cnt += 1
			if ReplacePattern.key? $1
				ReplacePattern[$1]
			else
				"(\\d*)"
			end
		}
		@pattern = Regexp.compile(pat_str)
		@for_sprinrf = format_str.gsub(FormatPattern, '%s')
	end
	def match(str)
		matched = @pattern.match(str)
		unless matched
			return nil
		end
		ret = Hash.new
		@idx_hash.each{|key, value|
			ret[key] = matched[value+1] #最初の一個はマッチ全体。
		}
		return ret
	end
	def format(hash)
		format_array = Array.new(@idx_hash.size, "")
		hash.each{|key, val|
			format_array[@idx_hash[key]] = val if @idx_hash.key? key
		}
		return sprintf(@for_sprinrf, *format_array);
	end
end

def getDefaultRunInfo
	info = Hash.new
	info[:in_format] = Formatter.new("%tid%-%stid%-%date%-%time%%channel%.%ext%");
	info[:out_format] = Formatter.new("%title% 第%stid%話 %subtitle% (%date%-%time%).%ext%");
	info[:dry_run] = false;
	info[:recursive] = false;
	info[:dont_ask] = false;
	info[:except_pettern] = Array.new
	return info
end

def rename(info, filename)
	basename = File::basename(filename)
	info[:except_pettern].each(){|pat|
		if pat == basename
			return
		end
	}
	file_info = info[:in_format].match(basename)
	unless file_info
		return
	end

	tid = file_info["tid"].to_i;
	if tid > 0
		stid = file_info["stid"].to_i

		title, subtitle = TitleResolver.getInstance.getTitleSet(tid,stid)
		number_of_subtitles = TitleResolver.getInstance.getNumberOfSubTitles(tid);
		unless number_of_subtitles > 0
			number_of_subtitles = 1000 #タイトル数が分からない場合はとりあえず大きめ。
		end

		digits_of_stid = 1+Math::log10(number_of_subtitles).to_i #最大の話数は何桁になる？
		file_info["stid"] = file_info["stid"].rjust([2,digits_of_stid].max,"0"); #話数のパディング←Vistaだとしなくてもうまくソート出来た気がするけど…

		renamed_title = info[:out_format].format( file_info.merge({"title" => title, "subtitle" => subtitle}))
	else
		renamed_title = EpgResolver.getInstance.getTitle(file_info["date"],file_info["time"],file_info["channel"])
		if renamed_title.size > FOLTIA_EPG_SUBTITLE_MAX
			renamed_title = renamed_title[0..(FOLTIA_EPG_SUBTITLE_MAX-1)];
		end
		renamed_title = file_info["date"]+"-"+file_info["time"]+"-"+file_info["channel"]+" "+renamed_title+"."+file_info["ext"]
	end

	renamed_path = File::join(File::dirname(filename),renamed_title)
	puts "\"#{filename}\" => \"#{renamed_path}\""
	unless info[:dry_run]
		if info[:dont_ask] || !FileTest.exist?(renamed_path)
			FileIndexRemover.getInstance.remove(basename);
			File::rename(filename, renamed_path)
		else
			accepted = false
			while !accepted
				print "\"#{renamed_path}\" overwrite? [y/n]: "
				$stdout.flush()
				buf = ($stdin.gets).strip
				accepted  = ( buf == "n" || buf == "y" )
			end
			if buf == "y"
				FileIndexRemover.getInstance.remove(basename);
				File::rename(filename, renamed_path)
			end
		end
	end
end

def enum(info,targets, depth)
	targets.each(){|target|
		filelist = Dir.glob(target);
		filelist.each{|filename|
			type = File::ftype(filename);
			if type == "directory"
				if info[:recursive]
					enum(info, [filename+"/*"],depth+1)
				elsif depth == 0 && FileTest::directory?(target)#フォルダ名を直接指定している場合、ということ。
					enum(info, [filename+"/*"],depth+1)
				end
			elsif  type == "file"
				rename(info, filename);
			end
		}
	}
#	title_resolver = TitleResolver.new()
#	puts title_resolver.getSubTitle(2099, 3)
end

Version = "1.0 (2011/04/28)"
Banner = <<EOF
=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-
ShoboCal_Renamer #{Version}
                   written by PSI ( http://ledyba.ddo.jp/ )
-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
usage: ruby #{$0} [options] files or directories
EOF

def main(argv = ARGV)
	opts = OptionParser.new(Banner)
	opts.program_name = "ShoboCal_Renamer"
	info = getDefaultRunInfo();
	opts.on("-i","--in_format FORMAT",String, /.*/, "入力ファイルのフォーマットを指定してください。"){|v|
		info[:in_format] = Formatter.new(v);
	}
	opts.on("-o","--out_format FORMAT",String , /.*/, "出力ファイルのフォーマットを指定してください。"){|v|
		info[:out_format] = Formatter.new(v);
	}
	opts.on("-d", "--dry-run", nil, "ファイル名を実際には書き換えません。") {|v|
		info[:dry_run] = true;
	}
	opts.on("-r", "--recursive", nil, "再帰的に実行します。") {|v|
		info[:recursive] = true;
	}
	opts.on("-e", "--except FILENAME", String, /.*/, "指定したファイルは除外します。") {|v|
		info[:except_pettern].push(v);
	}
	opts.on("-y", TrueClass, nil,"上書きが必要な際に、その旨を聞きません。") {|v|
		info[:dont_ask] = true
	}
	opts.on_tail("-h", "--help", "このメッセージを表示します") {
	  puts opts.help
	  exit
	}
	opts.on_tail("--version", "バージョンを表示します。") {
	  puts opts.ver
	  exit
	}

	opts.parse!(argv)
	enum(info,argv, 0);
end

main
