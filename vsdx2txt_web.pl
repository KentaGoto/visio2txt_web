use Mojolicious::Lite;
use File::Copy;
use open IO => qw/:encoding(UTF-8)/;
use HTML::Entities;
use XML::Twig;
use File::Find::Rule;
use File::Basename qw/basename dirname fileparse/;
use FindBin;
use Cwd;
use Archive::Zip qw( :ERROR_CODES :CONSTANTS :MISC_CONSTANTS );
use File::Path 'rmtree';
use File::Spec;
use Encode qw/encode decode/;

#binmode STDOUT, ':encoding(UTF-8)';

my $app = app;
my $url = 'http://localhost:3002'; # URL

my $UPLOAD_DIR = app->home->rel_file('/upload');
my $TMP_DIR = app->home->rel_file('/tmp');
my $PROC_TMP_DIR = 'proc_tmp';

my @texts;

get '/vsdx2txt' => sub {
	my $c = shift;

	# キャッシュを残さない。
	# この設定がないと、ブラウザの戻るボタンでトップページに戻ってきた際に、選択したzipファイルを変更して実行しても以前選択したzipファイルで実行されてしまう。
	# FirefoxやEdgeではこの挙動となった。Chromeではこの挙動とはならなかった。2018/01/18
	$c->res->headers->header("Cache-Control" => "no-store, no-cache, must-revalidate, max-age=0, post-check=0, pre-check=0", 
							 "Pragma"        => "no-cache"
							);

	$c->render('index', top_page => $url);

	@texts = (); # リセット

	# uploadフォルダがなければ作成する
	if ( !-d $UPLOAD_DIR ){
		mkdir $UPLOAD_DIR or die "Can not create directory $UPLOAD_DIR";
	}
	# tmpフォルダがなかったら作る
	if ( -d $TMP_DIR ){
	
	} else {
		mkdir $TMP_DIR, 0700 or die "$!";
	}
	undef($c);
};

post '/vsdx2txt' => sub {
    my $c = shift;
	my $nfn = $c->param('nfn');

    # 処理対象zipファイル
    my $file = $c->req->upload('files');
    my $zip_filename = $file->filename;
    
    # zip以外受け付けない
    unless ( $zip_filename =~ /\.zip$/ ){
    	return $c->render(
    		template => 'error', 
    		message  => "Error",
    		message2 => "Upload fail. The selected file is not an ZIP file.",
    	);
    }

	# Local time settings
	my $times = time();
	my ($sec, $min, $hour, $mday, $month, $year, $wday, $stime) = localtime($times);
	$month++;
	my $datetime = sprintf '%04d%02d%02d%02d%02d%02d', $year + 1900, $month, $mday, $hour, $min, $sec;

	# uploadディレクトリに日付フォルダ作成
	chdir $UPLOAD_DIR;
	if ( !-d $datetime ){
		mkdir $datetime or die "Can not create directory $datetime";
	}
    
    # アップロードされたファイルを保存
    my $upload_save_file = "$UPLOAD_DIR/" . "$datetime/" . $zip_filename;
    $file->move_to($upload_save_file);
    
	# tmpディレクトリに日付フォルダ作成
	chdir $TMP_DIR;
	if ( !-d $datetime ){
		mkdir $datetime or die "Can not create directory $datetime";
	}

	# tmpフォルダにも処理対象ファイルを移す
	my $tmp_save_file = "$TMP_DIR/" . "$datetime/" . $zip_filename;
	$file->move_to($tmp_save_file);
	
	# Zip解凍
	chdir $datetime;
	my $datetime_fullpath = "$TMP_DIR/$datetime";
	&unzip(\$zip_filename, $datetime_fullpath);

	# zip展開後はzipを削除
	unlink $tmp_save_file;

	# 処理ディレクトリとなるproc_tmpフォルダを作成
	mkdir $PROC_TMP_DIR or die "Can not create directory $PROC_TMP_DIR";
	
	# proc_tmpフォルダのフルパス
	my $PROC_TMP_DIR_abs = "$TMP_DIR/$datetime/$PROC_TMP_DIR";

	###############################################
	#          vsdxからテキスト抽出処理           
	###############################################
	my @vsdxs = File::Find::Rule->file->name( '*.vsdx' )->in(getcwd);
	
	foreach (@vsdxs){
		my $vsdx_fullpath = $_;
		my $vsdx_filename = basename($vsdx_fullpath);
		my $vsdx_dirname  = dirname($vsdx_fullpath);
		print "\n" . "Processing... " . $vsdx_filename . "\n";
	
		# [ファイル名区切りを出力する]がオンの場合
		if ( defined $nfn ){
			my $vsdx_filename_decode = decode('CP932', $vsdx_filename);
			push (@texts, "\n\n------------------------------$vsdx_filename_decode------------------------------");
		} else {
			# オフの場合は何もしない
		}
		
		# vsdxをtmpフォルダに移動してzipにする。
		my $zip = &vsdxCopy2tmp($vsdx_filename, $vsdx_dirname, $PROC_TMP_DIR_abs);
	
		chdir $PROC_TMP_DIR;
	
		# zip解凍
		&unzip(\$zip, $PROC_TMP_DIR_abs);
	
		# 展開後のzipを削除
		unlink $zip;
	
		# 要らないxmlを削除する
		unlink glob '*.xml';
	
		my @xmls = File::Find::Rule->file->name( qr/page\d+\.xml$/ )->in(getcwd);
	
		# 対象のxmlファイルを4桁にリネームしてproc_tmpフォルダにコピーする
		# ※何故リネームするか: 桁を揃えることで、処理するファイルを順番通りにするため。page1.xmlの次にpage10.xmlが処理されないようにするため。
		&xml_rename_and_copy(\@xmls, $PROC_TMP_DIR_abs);
	
		# 要らないフォルダを削除
		&del_dir($PROC_TMP_DIR_abs);
		
		# tmpフォルダにコピーしたxmlを対象とする
		my @target_xmls = glob '*.xml';
	
		# xmlをパースしてテキストをゲットする
		&xml_parser(\@target_xmls);
		
		# 対象ファイルの*.xmlを削除する
		unlink glob '*.xml';
	}

	# resultsページに移り、抽出したテキストをリダイレクトする
	$c->redirect_to('/vsdx2txt/results');
	
} => 'upload';

get '/vsdx2txt/results' => sub {
    my $c = shift;
	@texts = grep $_ !~ /^\s*$/, @texts; # 空白のみまたは空は捨てる
	$c->render('results', 'texts' => \@texts);
};

sub vsdxCopy2tmp {
	my ($vsdx_filename, $vsdx_dirname, $PROC_TMP_DIR_abs) = @_;
	my $zip;
	$zip = $vsdx_filename;
	$zip =~ s|^(.+)$|$1\.zip|;
	copy($vsdx_dirname . '/' . $vsdx_filename, "$PROC_TMP_DIR_abs/$zip") or die $!;
	return $zip;
}

sub unzip {
	my ($zip, $DIR) = @_;
	my $zip_obj = Archive::Zip->new($$zip);
	my @zip_members = $zip_obj->memberNames();
	foreach (@zip_members) {
		$zip_obj->extractMember($_, "$DIR/$_");
	}
}

sub xml_rename_and_copy {
	my ($xmls, $PROC_TMP_DIR_abs) = @_;
	foreach (@$xmls){
		my $file_src = $_;
		my $file_dst;
		if ( $file_src =~ m|^(.+?/)(page[0-9]\.xml)$| ){ # 1桁の場合
			$file_dst = $file_src;
			$file_dst =~ s|^(.+?/)(page)([0-9])(\.xml)$|${2}000$3$4|;
			my $file_dst_basename = basename($file_dst);
			print $PROC_TMP_DIR_abs . "\\" . $file_dst_basename . "\n";
			copy($file_src, "$PROC_TMP_DIR_abs/$file_dst_basename") or die "Error: $!";
		} elsif ( $file_src =~ m|^(.+?/)(page[0-9]{2,2}\.xml)$| ){ # 2桁の場合
			$file_dst = $file_src;
			$file_dst =~ s|^(.+?/)(page)([0-9]{2,2})(\.xml)$|${2}00$3$4|;
			my $file_dst_basename = basename($file_dst);
			print $PROC_TMP_DIR_abs . "\\" . $file_dst_basename . "\n";
			copy($file_src, "$PROC_TMP_DIR_abs/$file_dst_basename") or die "Error: $!";
		} elsif ( $file_src =~ m|^(.+?/)(page[0-9]{3,3}\.xml)$| ){ # 3桁の場合
			$file_dst = $file_src;
			$file_dst =~ s|^(.+?/)(page)([0-9]{3,3})(\.xml)$|${2}0$3$4|;
			my $file_dst_basename = basename($file_dst);
			print $PROC_TMP_DIR_abs . "\\" . $file_dst_basename . "\n";
			copy($file_src, "$PROC_TMP_DIR_abs/$file_dst_basename") or die "Error: $!";
		}
		else {
			print $file_src . "\n";
			print "Error: The number of pages exceeds 1000.";
			exit;
		}
	}
}

sub del_dir {
	my ($PROC_TMP_DIR_abs) = shift;
	rmtree("$PROC_TMP_DIR_abs/visio") or die $!;
	rmtree("$PROC_TMP_DIR_abs/docProps") or die $!;
	rmtree("$PROC_TMP_DIR_abs/_rels") or die $!;
}

sub xml_parser {
	my ($target_xmls) = shift;
	foreach my $xml ( @$target_xmls ){
		my $twig = new XML::Twig( TwigRoots => {
				'//Text' => \&output_target,
				});
		$twig->parsefile( $xml );
	}
}

sub output_target {
	my( $tree, $elem ) = @_;
	my $target = $elem->text;
	push (@texts, $target);
	
	{
		local *STDOUT;
		local *STDERR;
  		open STDOUT, '>', undef;
  		open STDERR, '>', undef;
		$tree->flush_up_to( $elem ); #Memory clear
	}
}

app->start;

__DATA__

@@ error.html.ep
<h1><%= $message %></h1>
<p><%= $message2 %></p>

@@ layouts/default.html.ep
<html>
<head>
<title><%= title %></title>
<meta http-equiv="Content-type" content="text/html; charset=UTF-8">
<%= stylesheet '/css/style.css' %>
<script src="https://ajax.googleapis.com/ajax/libs/jquery/3.2.1/jquery.min.js"></script>
</head>
<body><%= content %></body>
</html>

@@ index.html.ep
% layout 'default';
% title 'vsdx2txt';
<div id="out">
<div id="head">
<h1>vsdx2txt</h1>
<form method="post" action="<%= url_for('upload') %>" enctype ="multipart/form-data">
	<input name="files" type="file" value="Select File" />
	<input type="submit" value="Run" />
	</br>
	<p>ファイル名区切りを出力する: <%= check_box nfn => 1 %></p>
</form>
	</div>
	<div id="main">
<h3>Usage</h3>
	<ul>
		<li><strong>vsdx</strong> ファイルの入った <strong>zip</strong> ファイルを選択します。</li>
		<li><strong>[Run]</strong> ボタンをクリックします。</li>
		<li>遷移した画面に <strong>vsdx</strong> から抽出したテキストが表示されます。</li>
	</ul>
<h3>Option</h3>
	<ul>
		<li><strong>[ファイル名区切りを出力する]</strong> チェックボックスをオンにすると、処理対象となった <strong>*.vsdx</strong> が抽出テキストの区切りとして出力されます。</li>
	</ul>
<h3>Requirements</h3>
	<ul>
		<li>Chrome or Firefox</li>
	</ul>
<h4>Note</h4>
<ul>
	<li>シート名は抽出されません。</li>
</ul>
</div>
<div id="footer">
Copyright &copy; KentaGoto All Rights Reserved.
</div>
</div>

@@ results.html.ep
<html>
<head>
% title 'Results';
<meta http-equiv="Content-type" content="text/html; charset=UTF-8">
<%= stylesheet '/css/style_Results.css' %>
</head>
<body>
% for my $t (@$texts){
	<%= $t %> </br>
% }
</body>
</html>
