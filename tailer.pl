use Mojolicious::Lite;  
use Mojo::IOLoop;
use Mojo::JSON;
use Mojo::Util qw(slurp);
use FindBin qw($Bin);
use lib "$Bin/lib";
use File::Path;
use File::Find;
use File::Basename;

use Data::Page;
use IO::File;
use Parse::Syslog::Line;

use Data::Dumper;

my $basename = basename $0, '.pl';
plugin Config => {
	default => {
		files => ['/var/log/syslog'],
	}
};
my $files = {};
my $page = Data::Page->new;
my @files = ();
my $load = sub {
	my $loop = shift;
	foreach my $file ( @{+app->config->{files}} ) {
		$files->{$file}->{size} ||= 0;
		if ( -s $file < $files->{$file}->{size} ) {
			warn "Reprocessing $file...\n";
			delete $files->{$file};
			@files = grep { $_->{file} ne $file } @files;
		} else {
			warn "Processing $file...\n";
		}
		$files->{$file}->{fh} = new IO::File $file, 'r' unless defined $files->{$file}->{fh};
		$files->{$file}->{size} = -s $file;
		my $fh = $files->{$file}->{fh} or next;
		warn "Reading $file...\n";
		for ( $files->{$file}->{curpos} = tell($files->{$file}->{fh}); $_ = <$fh>; $files->{$file}->{curpos} = tell($files->{$file}->{fh}) ) {
			chomp;
			$_ = parse_syslog_line($_);
			$_->{file} = basename $file, '.log';
			$_->{id} = $#files;
			push @files, $_;
		}
		warn "Total lines: $#files\n";
		seek($files->{$file}->{fh}, $files->{$file}->{curpos}, 0);
	}
};

app->config(version => slurp "$Bin/.ver");
app->config(hypnotoad => {pid_file=>"$Bin/../.$basename", listen=>[split ',', $ENV{MOJO_LISTEN}||'https://*'], proxy=>$ENV{MOJO_REVERSE_PROXY}||1});
helper json => sub {
	my $self = shift;
	unless ( $self->{__JSON} ) {
		my $json = new Mojo::JSON;
		$self->{__JSON} = $json->decode($self->req->body);
	}
	return $self->{__JSON}||{};
};

get '/' => 'index';

post '/messages' => sub {
	my $self = shift;
        my ($field, $oper, $string) = map { $self->json->{$_} } qw/searchField searchOper searchString/;
        my ($sidx, $sord) = map { $self->json->{$_} } qw/sidx sord/;

	my $rows;
	$page->entries_per_page($self->json->{rows}||20);
	$page->current_page($self->json->{page}||1);

	# Sort
	$sidx ||= 'datetime_str';
	given ( $sord ) {
		when ( 'desc' ) { $rows = [sort { $b->{$sidx} cmp $a->{$sidx} } @files] }
		default { $rows = [sort { ($a->{$sidx}||'') cmp ($b->{$sidx}||'') } @files] }
	}

	# Search
	if ( $field && $oper && defined $string ) {
		given ( $oper ) {
			when ( 'eq' ) { $rows = [grep { $_->{$field} eq $string } @$rows] }
			when ( 'ne' ) { $rows = [grep { $_->{$field} ne $string } @$rows] }
			when ( 'bw' ) { $rows = [grep { $_->{$field} =~ /^$string/ } @$rows] }
			when ( 'bn' ) { $rows = [grep { $_->{$field} !~ /^$string/ } @$rows] }
			when ( 'ew' ) { $rows = [grep { $_->{$field} =~ /$string$/ } @$rows] }
			when ( 'en' ) { $rows = [grep { $_->{$field} !~ /$string$/ } @$rows] }
			when ( 'cn' ) { $rows = [grep { $_->{$field} =~ /$string/ } @$rows] }
			when ( 'nc' ) { $rows = [grep { $_->{$field} !~ /$string/ } @$rows] }
		}
	}

	# Render
	$page->total_entries($#$rows+1);
	my @rows = @$rows[$page->first-1..$page->last-1];
	$self->render_json({
		page => $page->current_page,
		total => $page->last_page,
		records => $page->total_entries,
		entries => $page->entries_per_page,
		rows => $#rows ? \@rows : [],
	});
};

&$load; Mojo::IOLoop->recurring(15 => $load);

app->start;

__DATA__
@@ grid.html.ep
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en" lang="en">
<head>
<meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
<title>Tailer <%= config 'version' %></title>
<link   href="http://ajax.googleapis.com/ajax/libs/jqueryui/1.8/themes/base/jquery-ui.css" type="text/css" rel="stylesheet" media="all" />
<link   href="/s/css/ui.jqgrid.css" rel="stylesheet" type="text/css" media="screen" />      
<script  src="http://ajax.googleapis.com/ajax/libs/jquery/1.8/jquery.min.js" type="text/javascript"></script>
<script  src="http://ajax.googleapis.com/ajax/libs/jqueryui/1.9.1/jquery-ui.min.js" type="text/javascript"></script>
<script  src="/s/js/i18n/grid.locale-en.js" type="text/javascript"></script>
<script  src="/s/js/jquery.jqGrid.min.js" type="text/javascript"></script>  
<script  src="/s/js/jquery.json-2.3.min.js" type="text/javascript"></script>
<style>
    * {font-family: Verdana,Arial,sans-serif;font-size: 11px;}
    #loggedin {display:none}
    .link {cursor:pointer;color:blue;text-decoration:underline;}
</style>
<script type="text/javascript">
$(document).ready(function(){  
    $.ajaxSetup({
	accepts: {
            json: "application/json"
	},
    });

    %= content grid => begin
    // Grid
    % end
});
</script>
</head>  
<body>
<table id="list1" class="scroll"></table> 
<div id="pager1" class="scroll" style="text-align:center;" />
</body>
</html>

@@ index.html.ep
% extends 'grid', title=>'File Contents';
% content grid => begin
$("#list1").jqGrid({
        url: '<%= url_for 'messages' %>',
        mtype: 'POST',
        datatype: 'json',
	accepts: {
		json: "application/json"
	},
        jsonReader: {repeatitems: false, id: "id"},
        ajaxGridOptions: {
		contentType: "application/json",
		headers: { 
			Accept : "application/json"
		}
	},
        serializeGridData: function (postData) { return $.toJSON(postData); },
        caption: "File Contents",
        colModel:[
            {name:'datetime_str',label:'Timestamp',width:40,editable:false,sortable:false},
            {name:'host_raw',label:'Hostname',width:40,editable:false,sortable:false},
            {name:'file',label:'Source',width:40,editable:false,sortable:false},
            {name:'facility',label:'Facility',width:20,editable:false,sortable:false},
            {name:'priority',label:'Priority',width:20,editable:false,sortable:false},
            {name:'content',label:'Message',editable:false,sortable:false}
        ],
        loadComplete: function (gridData) {
            $("#jqgh_list1_datetime_str").css("cursor", "default");
            $("#jqgh_list1_host_raw").css("cursor", "default");
            $("#jqgh_list1_file").css("cursor", "default");
            $("#jqgh_list1_facility").css("cursor", "default");
            $("#jqgh_list1_priority").css("cursor", "default");
            $("#jqgh_list1_content").css("cursor", "default");
        },
        recreateForm: true,
        altRows: true,
        rownumbers: true,
        rownumWidth: 50,
        scroll: false,
        rowNum: 25,
        rowList: [10, 25, 50, 100, 500, 1000, 5000, 10000],
        pager: '#pager1',
        viewrecords: true,
        height: "75\%",
        autowidth: true
});
$("#list1").jqGrid('navGrid','#pager1',
        {edit:false,add:false,del:false},
        // {edit}, {add}, {del}, {search}, {view}
        {},
        {},
        {},
        {},
        {}
);
setInterval('$("#list1").trigger("reloadGrid")',15000);
% end
