package S2B;

use v5.18;
use utf8;

use Moo;

use Encode qw( encode decode );
use HTTP::Tiny;
use List::MoreUtils qw( uniq );
use List::Util qw( max );
use Mojo::DOM;
use Path::Tiny;
use URI::Escape;

has http => (
    is => 'lazy',
);

has category => (
    is      => 'ro',
    builder => '_build_category',
);

has agent => (
    is      => 'ro',
    default => 'Mozilla/5.0 (compatible; MSIE 8.0; Windows NT 6.1; Trident/4.0; GTB7.4; InfoPath.2; SV1; .NET CLR 3.3.69573; WOW64; en-US)',
);

has base_url => (
    is      => 'ro',
    default => 'http://www.s2b.kr',
);

has category_url => (
    is      => 'ro',
    default => '/S2BNCustomer/S2B/scrweb/remu/rema/searchengine/s2bCustomerSearch.jsp',
);

has detail_url => (
    is      => 'ro',
    default => '/S2BNCustomer/rema100No.do',
);

sub search_product {
    my $self  = shift;
    my $query = shift;
    my $count = shift || 10;

    return unless $query;

    my %params = (
        actionType         => 'MAIN_SEARCH',
        startIndex         => 0,
        searchQuery        => $query,
        searchField        => 'MODEL',
        viewCount          => $count,
        viewType           => 'LIST',
        sortField          => 'PCAC',
    );

    return $self->_get_product_codes(\%params);
}

sub _get_product_codes {
    my ( $self, $params ) = @_;

    my %p              = %$params;
    my $search_query   = delete $p{searchQuery};
    my $search_requery = delete $p{searchRequery};

    my $url = $self->base_url . $self->category_url;
    $url .= '?' .  HTTP::Tiny->www_form_urlencode(\%p);
    if ($search_query) {
        $url .= '&searchQuery=';
        $url .= uri_escape( encode( "cp949", $search_query ) );
    }
    if ($search_requery) {
        $url .= '&searchRequery=';
        $url .= uri_escape( encode( "cp949", $search_requery ) );
    }

    my $res = $self->http->get($url);
    my $dom = Mojo::DOM->new( decode( 'euc-kr', $res->{content} ) );

    my %goods;
    $dom->find('a')->each(sub {
        my $href = $_->attr('href');

        return unless $href =~ m/javascript:goViewPage\('(\d+)'\)/;

        $goods{$1}++;
    });

    return keys %goods;
}

sub filter_path {
    my ( $self, $str ) = @_;

    $str =~ s{[^ \w\.\-_()\[\]]}{_}gms;
    $str =~ s{(^\s+|\s+$)}{}gms;
    $str =~ s{\s+}{ }gms;

    return $str;
}

sub save_images {
    my ( $self, $target_dir, $target_prefix, $urls ) = @_;

    for ( my $i = 0; $i < @$urls; ++$i ) {
        my $res = $self->http->get( $urls->[$i] );
        next unless $res->{success};

        my $no = $i + 1;
        path("$target_dir/$target_prefix-$no.jpg")->touchpath->spew_raw( $res->{content} );
    }
}

sub parse_category {
    my ( $self, $category, $level ) = @_;

    my ( $c1, $c2, $c3 ) = $category =~ m/^(...)(....)(.....)$/;

    return sprintf( '%03s%04s%05s', $c1, 0,   0 ) if $level == 1;
    return sprintf( '%03s%04s%05s', $c1, $c2, 0 ) if $level == 2;
    return $category;
}

sub get_product {
    my ( $self, $code ) = @_;

    return unless $code;

    my %params = (
        forwardName        => 'detail',
        f_re_estimate_code => $code,
    );

    my $url = $self->base_url . $self->detail_url;
    $url .= '?' .  HTTP::Tiny->www_form_urlencode(\%params);

    my $res = $self->http->get($url);
    my $dom = Mojo::DOM->new( decode( 'euc-kr', $res->{content} ) );

    my %result = (
        code => $code,
        url  => $url,
    );

    #
    # category
    #
    {
        my $count = 0;
        my ( $c1_str, $c2_str, $c3_str );
        $dom->find("center table tr td table tr td form table tr td")->each(sub {
            return unless $_->attr('align') eq 'left';
            return if     $count++;

            ( $c1_str, $c2_str, $c3_str ) = split / > /, $_->all_text;
        });

        $result{c1_str} = $c1_str;
        $result{c2_str} = $c2_str;
        $result{c3_str} = $c3_str;
        $result{c1}     = $self->category->{reverse}{1}{$c1_str};
        $result{c2}     = $self->category->{reverse}{2}{$c2_str};

        my $c3_candidate = $self->category->{reverse}{3}{$c3_str};
        for my $c3 (@$c3_candidate) {
            my $c2 = $self->parse_category( $c3, 2 );
            next unless $c2 eq $result{c2};

            $result{c3} = $c3;
            last;
        }
    }

    #
    # 이미지
    #
    $dom->find('td.detail_img img')->each(sub {
        my $img = $_->attr('src');
        return if $img =~ m/none_img02.gif/;

        push @{ $result{images} }, $img;
    });
    @{ $result{images} } = uniq @{ $result{images} };

    if ( $dom->at('#editor-content p img') ) {
        push @{ $result{images} }, $dom->at('#editor-content p img')->attr('src');
    }
    if ( $dom->at('#editor-content + img') ) {
        push @{ $result{images} }, $dom->at('#editor-content + img')->attr('src');
    }

    #
    # 물품명
    #
    if ( my $e = $dom->at('font.f12_b_black') ) {
        my $v = $e->text;

        $result{name} = $v;
    }

    #
    # 상세 정보
    #
    my $table = $dom->at('font.f20_red')->parent->parent->parent->parent->parent->parent;
    $table->children('tr')->each(sub {
        if ( my $e = $_->at('font.f20_red') ) {
            my $v = $e->text;
            $v =~ s/[^0-9]//g;

            $result{price} = $v;
        }
        else {
            return unless $_->at('td.f_pad15');

            my $k = $_->at('td.f_pad15')->all_text;
            my $v = $_->at('td.f12_c3')->all_text;

            no warnings 'experimental';
            given ($k) {
                when ('모델명 / 규격') {
                    my ( $v1, $v2 ) = split / \/ /, $v, 2;
                    $v2 =~ s/^ +//g if $v2;

                    $result{model} = $v1;
                    $result{spec}  = $v2;
                }
                when ('제조사 / 원산지') {
                    my ( $v1, $v2 ) = split / \/ /, $v, 2;
                    $v2 =~ s/^ +//g if $v2;

                    $result{manufactory} = $v1;
                    $result{made_in}     = $v2;
                }
                when ('제조일자 / 유통기한') {
                    my ( $v1, $v2 ) = split / \//, $v, 2;
                    $v2 =~ s/^ +//g if $v2;

                    $result{manufactured_date} = $v1;
                    $result{expiration_date}   = $v2;
                }
                when ('과세유무') {
                    $result{tax} = $v;
                }
                when ('물품목록번호') {
                    $result{serial1} = $v;
                }
                when ('세부품명번호') {
                    $result{serial2} = $v;
                }
                when ( m{(품질보증정보|주문수량 / 판매단위|인증정보|납품가능기한)} ) {
                    # skip data
                }
                default {
                    $result{$k} = $v;
                }
            }
        }
    });

    return \%result;
}

sub _build_http { HTTP::Tiny->new( agent => $_[0]->agent ) }

sub _build_category {
    my %level1 = (
        101000000000 => '가구',
        102000000000 => '학습교구/기자재',
        103000000000 => '문구사무용품',
        104000000000 => '컴퓨터/전산용품',
        105000000000 => '전자제품/사무기기',
        106000000000 => '토너/잉크',
        107000000000 => '청소/보건/위생/생활',
        108000000000 => '급식',
        109000000000 => '식품',
        110000000000 => '의약품',
        111000000000 => '산업안전시설용품',
        112000000000 => '행사/판촉용품',
        113000000000 => '도서',
    );
    my %level2 = (
        101000100000 => '과학실험실가구',
        101000200000 => '기숙사가구',
        101000300000 => '도서열람용가구',
        101000400000 => '급식실가구',
        101000500000 => '사무용가구',
        101000600000 => '학생용가구',
        101000700000 => '침구/커튼/인테리어',
        102000100000 => '영어교구',
        102000200000 => '수학교구',
        102000300000 => '과학교구',
        102000400000 => '음악교구',
        102000400000 => '음악교구',
        102000500000 => '미술교구',
        102000600000 => '체육교구',
        102000700000 => '영상기기',
        102000800000 => '영상/소프트웨어',
        102000900000 => '국어교구',
        102001000000 => '사회교구',
        102001100000 => '기술/가정교구',
        102001200000 => '유아교구',
        102001300000 => '특수교구',
        103000100000 => '지류',
        103000200000 => '필기구',
        103000300000 => '화일/바인더',
        103000400000 => '일반사무용품',
        103000500000 => '칠판/보드',
        104000100000 => '공미디어/케이스',
        104000200000 => '저장장치/USB',
        104000300000 => '데스크탑',
        104000400000 => '노트북',
        104000500000 => '태블릿 PC',
        104000600000 => '모니터',
        104000700000 => '프린터/스캐너',
        104000800000 => '주변기기/소모품',
        105000100000 => '사무기기',
        105000200000 => '생활가전',
        105000300000 => '영상기기',
        105000400000 => '음향기기',
        105000500000 => '계절가전',
        105000600000 => '카메라/캠코더',
        105000700000 => '소형전자제품',
        106000100000 => '토너카트리지(정품)',
        106000200000 => '토너카트리지(재생)',
        106000300000 => '잉크카트리지(정품)',
        106000400000 => '잉크카트리지(재생)',
        106000500000 => '등사잉크(정품)',
        106000600000 => '등사잉크(재생)',
        106000700000 => '리본/리본카트리지',
        107000100000 => '청소용품',
        107000200000 => '세제/왁스',
        107000300000 => '위생소모품',
        107000400000 => '화장지/타올',
        107000500000 => '위생/검진기구',
        107000600000 => '보건용품',
        107000700000 => '생활용품',
        107000800000 => '의약외품',
        108000100000 => '급식가전/설비',
        108000200000 => '급식기구/소모품',
        109000100000 => '신선식품',
        109000200000 => '가공식품',
        110000100000 => '중추신경계용약',
        110000200000 => '감각기관용약',
        110000300000 => '알레르기용약',
        110000400000 => '호흡기관용약',
        110000500000 => '소화기관용약',
        110000600000 => '비뇨생식용약',
        110000700000 => '외피용약',
        110000800000 => '혈액및체액용약',
        111000100000 => '전등/램프/LED',
        111000200000 => '안전/소방',
        111000300000 => '구조물/설치물',
        111000400000 => '공구/기계',
        111000500000 => '철물',
        111000600000 => '화공/소독',
        111000700000 => '케이블/절연',
        111000800000 => '전기자재',
        111000900000 => '페인트',
        111001000000 => '정보/통신',
        111001100000 => '조경(수목)',
        112000100000 => '판촉용품',
        112000200000 => '행사용품',
        113000100000 => '영유아',
        113000200000 => '초등',
        113000300000 => '중/고등',
        113000400000 => '대학',
        113000500000 => '사전/기타',
        113000600000 => '컴퓨터/IT',
        113000700000 => '정기간행물/여행/기행',
        113000800000 => '건강/취미/레저',
        113000900000 => '가정/요리/뷰티',
        113001000000 => '철학/종교/역학',
        113001100000 => '수험서/자격증',
        113001200000 => '문학/예술/문화',
        113001300000 => '사회/경제/과학',
    );
    my %level3 = (
        103000100001 => '복사용지',
        103000100002 => '전용지',
        103000100003 => '등사원지',
        103000100004 => '라벨/견출지',
        103000100005 => '메모지/노트',
        103000100006 => '색종이/색지',
        103000100007 => '다이어리/수첩',
        103000100008 => '봉투류',
        103000100009 => '금전출납부',
        103000100010 => '중절지/신문용지',
        103000100011 => '기타',
        103000100012 => '코팅지/코팅필름',
        103000200001 => '고급펜/만년필',
        103000200002 => '볼펜',
        103000200003 => '연필/샤프류',
        103000200004 => '젤러펜/중성펜',
        103000200005 => '수성펜/유성펜',
        103000200006 => '사인펜/색연필',
        103000200007 => '매직/네임펜',
        103000200008 => '형광펜/붓펜',
        103000200009 => '제도용펜/특수펜',
        103000200010 => '필기구세트',
        103000200011 => '기타',
        103000300001 => '클리어화일/속지',
        103000300002 => '특수화일',
        103000300003 => '바인더',
        103000300004 => '보관함/문서보관상자',
        103000300005 => '서류함',
        103000300006 => '서류철/결제판',
        103000300007 => '명함철',
        103000300008 => '앨범',
        103000300009 => '상장케이스',
        103000300010 => '기타',
        103000400001 => '수정용품/지우개',
        103000400002 => '테이프',
        103000400003 => '풀/접착제/본드류',
        103000400004 => '스테플러/펀치류',
        103000400005 => '칼/가위/자',
        103000400006 => '명찰/철/묶음',
        103000400007 => '인주/스탬프/인장류',
        103000400008 => '기타',
        103000400009 => '클립/집게',
        103000400010 => '건전지/수은전지',
        103000400011 => '계산기',
        103000400012 => '제본링/카드링',
        103000500001 => '화이트보드/칠판',
        103000500002 => '보드마카/보드지우개',
        103000500003 => '분필/흑판지우개',
        103000500004 => '게시판',
        103000500005 => '기타',
        101000100001 => '실험기구진열장',
        101000100002 => '실험대',
        101000100003 => '실험실용씽크대',
        101000100004 => '의자',
        101000100005 => '기타',
        101000200001 => '수납함/서랍장',
        101000200002 => '옷장/락커',
        101000200003 => '의자',
        101000200004 => '책상',
        101000200005 => '침대',
        101000200006 => '신발장',
        101000300001 => '독서대',
        101000300002 => '서가',
        101000300003 => '열람대',
        101000300004 => '의자',
        101000300005 => '북트럭/반납함',
        101000300006 => '잡지가/신문걸이',
        101000300007 => '기타',
        101000400001 => '식탁',
        101000400002 => '의자',
        101000400003 => '선반/작업대',
        101000400004 => '기타',
        101000500001 => '금고',
        101000500002 => '교탁/사회대',
        101000500003 => '소파',
        101000500004 => '의자',
        101000500005 => '책상',
        101000500006 => '책장/옷장/사물함',
        101000500007 => '케비넷',
        101000500008 => '테이블',
        101000500009 => '파티션/부품',
        101000500010 => '기타',
        101000500011 => '이동서랍',
        101000600001 => '신발장',
        101000600002 => '의자',
        101000600003 => '책상',
        101000600004 => '책장/사물함',
        101000600005 => '기타',
        101000700001 => '침구',
        101000700002 => '베개/쿠션/방석',
        101000700003 => '이불솜/베개솜',
        101000700004 => '블라인드/롤스크린',
        101000700005 => '커튼/로만쉐이드',
        101000700006 => '카페트/매트',
        101000700007 => '시트지/벽지',
        101000700008 => '수납/인테리어소품',
        101000700009 => '기타',
        104000100001 => '디스켓',
        104000100002 => 'CD',
        104000100003 => 'DVD',
        104000100004 => '케이스',
        104000100005 => '기타',
        104000200001 => 'USB 메모리',
        104000200002 => '외장HDD',
        104000200003 => '메모리카드',
        104000200004 => '기타',
        104000300001 => '삼성',
        104000300002 => 'LG',
        104000300003 => '삼보',
        104000300004 => '델',
        104000300005 => 'HP',
        104000300006 => '주연테크',
        104000300007 => '늑대와여우',
        104000300008 => '대우루컴즈',
        104000300009 => '레드스톤',
        104000300010 => '기타',
        104000400001 => '삼성',
        104000400002 => 'LG',
        104000400003 => '삼보',
        104000400004 => '델',
        104000400005 => 'HP',
        104000400006 => '주연테크',
        104000400007 => '늑대와여우',
        104000400008 => '대우루컴즈',
        104000400009 => '레드스톤',
        104000400010 => '기타',
        104000500001 => '삼성',
        104000500002 => 'LG',
        104000500003 => '삼보',
        104000500004 => '델',
        104000500005 => 'HP',
        104000500006 => '주연테크',
        104000500007 => '늑대와여우',
        104000500008 => '대우루컴즈',
        104000500009 => '레드스톤',
        104000500011 => 'APPLE',
        104000500012 => '아이뮤즈',
        104000500013 => 'ASUS',
        104000500014 => '아이스테이션',
        104000500015 => '한성',
        104000500016 => 'ACER',
        104000500017 => 'SONY',
        104000500010 => '기타',
        104000600001 => '삼성',
        104000600002 => 'LG',
        104000600003 => '삼보',
        104000600004 => '델',
        104000600005 => 'HP',
        104000600006 => '주연테크',
        104000600007 => '늑대와여우',
        104000600008 => '대우루컴즈',
        104000600009 => '레드스톤',
        104000600010 => '기타',
        104000700001 => '잉크젯',
        104000700002 => '레이저젯',
        104000700003 => '소형복합기',
        104000700004 => '스캐너',
        104000700005 => '플로터',
        104000700006 => '기타',
        104000800001 => '키보드',
        104000800002 => '마우스',
        104000800003 => 'PC 스피커',
        104000800004 => '이어폰/헤드폰',
        104000800005 => 'PC Cam',
        104000800006 => '타블렛',
        104000800007 => '네트워크장비',
        104000800008 => '컴퓨터 액세서리',
        104000800009 => '컴퓨터 부품',
        104000800010 => '공유기',
        104000800011 => '케이블',
        104000800012 => '네트워크 소모품',
        104000800013 => '소프트웨어',
        104000800014 => '레이저 포인터',
        104000800015 => '기타 주변기기/소모품',
        106000100001 => 'HP',
        106000100002 => '삼성전자',
        106000100003 => 'CANON',
        106000100004 => 'EPSON',
        106000100005 => '후지제록스',
        106000100006 => '신도리코',
        106000100007 => '기타제조사',
        106000200001 => 'HP',
        106000200002 => '삼성전자',
        106000200003 => 'CANON',
        106000200004 => 'EPSON',
        106000200005 => '후지제록스',
        106000200006 => '신도리코',
        106000200007 => '기타제조사',
        106000300001 => 'HP',
        106000300002 => '삼성전자',
        106000300003 => 'CANON',
        106000300004 => 'EPSON',
        106000300005 => '후지제록스',
        106000300006 => '신도리코',
        106000300007 => '기타제조사',
        106000400001 => 'HP',
        106000400002 => '삼성전자',
        106000400003 => 'CANON',
        106000400004 => 'EPSON',
        106000400005 => '후지제록스',
        106000400006 => '신도리코',
        106000400007 => '기타제조사',
        106000500001 => 'RISO',
        106000500002 => '한일듀프로',
        106000500003 => '신도테크노',
        106000500004 => '삼일',
        106000500005 => '기타제조사',
        106000600001 => 'RISO',
        106000600002 => '한일듀프로',
        106000600003 => '신도테크노',
        106000600004 => '삼일',
        106000600005 => '기타제조사',
        106000700001 => '카트리지',
        106000700002 => '리본',
        106000700003 => '기타',
        105000100001 => '복사기/복합기',
        105000100002 => '전화기/팩스',
        105000100003 => '문서세단기',
        105000100004 => '금고',
        105000100005 => '천공기/라미네이터',
        105000100006 => '제본기',
        105000100007 => '코팅기',
        105000100008 => '세단기',
        105000100009 => '기타 사무기기',
        105000200001 => '냉장고',
        105000200002 => '세탁기',
        105000200003 => '공기청정기',
        105000200004 => '산업용 청소기',
        105000200005 => '일반 청소기',
        105000200006 => '소형전기주전자',
        105000200007 => '기타',
        105000200008 => '스탠드',
        105000200009 => '전자레인지',
        105000200010 => '다리미',
        105000200011 => '제봉틀(미싱기)',
        105000200012 => '드라이기',
        105000300001 => 'TV',
        105000300002 => '프로젝터/스크린',
        105000300003 => 'DVD/비디오 플레이어',
        105000300004 => '기타',
        105000400001 => '홈씨어터',
        105000400002 => '앰프',
        105000400003 => '오디오',
        105000400004 => '마이크',
        105000400005 => '녹음기',
        105000400006 => '기타',
        105000500001 => '냉난방기',
        105000500002 => '선풍기',
        105000500003 => '히터',
        105000500004 => '온풍기',
        105000500005 => '라디에이터',
        105000500006 => '온열매트(전기장판)',
        105000500007 => '기타',
        105000600001 => 'DSLR카메라',
        105000600002 => 'DSLR렌즈',
        105000600003 => '컴팩트/하이앤드',
        105000600004 => '캠코더',
        105000600005 => '배터리/충전기',
        105000600006 => '삼각대/가방',
        105000600007 => '액세서리',
        105000600008 => '필름',
        105000600009 => '폴라로이드',
        105000600010 => '기타',
        105000700001 => '전자사전/PMP',
        105000700002 => 'MP3',
        105000700003 => '네비게이션',
        105000700004 => '기타',
        107000100001 => '빗자루/쓰레받이',
        107000100002 => '워터릴/호스',
        107000100003 => '걸레/걸레봉',
        107000100004 => '수세미',
        107000100005 => '쓰레기통(스텐)',
        107000100006 => '쓰레기통(플라스틱)',
        107000100007 => '분리수거함',
        107000100008 => '청소솔',
        107000100009 => '기타',
        107000200001 => '기구용',
        107000200002 => '야채과일용',
        107000200003 => '주방용',
        107000200004 => '세척기용',
        107000200005 => '세탁/욕실용',
        107000200006 => '청소용',
        107000200007 => '손소독/세정',
        107000200008 => '기타',
        107000300001 => '방부제',
        107000300002 => '방역용살균소독제',
        107000300003 => '방충제',
        107000300004 => '살충제',
        107000300005 => '기타 공중위생용약',
        107000300006 => '마스크',
        107000300007 => '구강청정제',
        107000300008 => '방향제',
        107000300009 => '기타',
        107000400001 => '롤화장지',
        107000400002 => '각티슈',
        107000400003 => '물티슈',
        107000400004 => '핸드/페이퍼타올',
        107000400005 => '냅킨',
        107000400006 => '디스펜서',
        107000400007 => '행주',
        107000400008 => '수건',
        107000400009 => '기타',
        107000500001 => '체온계',
        107000500002 => '핀셋/핀셋통',
        107000500003 => '농반/가제통/소독접시',
        107000500004 => '구급낭',
        107000500005 => '보행/보조',
        107000500006 => '찜질용기구',
        107000500007 => '호흡보조기구',
        107000500008 => '기타응급처치기구',
        107000500009 => '혈압계',
        107000500010 => '혈당계',
        107000500011 => '저울/체중계',
        107000500012 => '시력판',
        107000500013 => '신장계',
        107000500014 => '체지방',
        107000500015 => '청력계',
        107000500016 => '기타검진기구',
        107000600001 => '구취 /액취 방지제',
        107000600002 => '보건 살충제',
        107000600003 => '구강위생제제',
        107000600004 => '건강진단/상담기구',
        107000600005 => '기타보건소모품',
        107000700001 => '면도기',
        107000700002 => '치약/칫솔',
        107000700003 => '비누',
        107000700004 => '장갑',
        107000700005 => '시계',
        107000700006 => '숟가락/젓가락',
        107000700007 => '용기/도시락',
        107000700008 => '쓰레기봉투/일반봉투',
        107000700009 => '크린백/위생봉투',
        107000700010 => '종이컵',
        107000700011 => '기타생활용품',
        107000800001 => '거즈/붕대/탈지',
        107000800002 => '귀/눈/입술/코',
        107000800003 => '마스크/방한대',
        107000800004 => '반창고/밴드',
        107000800005 => '보호대/교정용품',
        107000800006 => '의료용구',
        107000800007 => '측정기기',
        107000800008 => '치아/구강용품',
        107000800009 => '기타',
        111000100001 => 'LED조명',
        111000100002 => '보안등기구',
        111000100003 => '백열전구',
        111000100004 => '삼파장전구',
        111000100005 => 'PL램프',
        111000100006 => '형광램프',
        111000100007 => '클립톤전구',
        111000100008 => '할로겐전구',
        111000100009 => '특수조명',
        111000100010 => '안전기',
        111000100011 => '전등용품',
        111000100012 => '인테리어 조명',
        111000100013 => '경광조명',
        111000100014 => '기타',
        111000200001 => '개인안전용품',
        111000200002 => '어린이안전용품',
        111000200003 => '공사안전용품',
        111000200004 => '교통안전용품',
        111000200005 => '안전매트',
        111000200006 => '기타',
        111000200007 => '소방안전용품',
        111000200008 => '수상안전용품',
        111000200009 => '안전표지판/테이프',
        111000200010 => '논스립(미끄럼방지)',
        111000300001 => '고정설치물',
        111000300002 => '이동설치물',
        111000300003 => '사인/광고물',
        111000300004 => '암막/방염스크린',
        111000400001 => '에어/유압공구',
        111000400002 => '측량/측정공구',
        111000400003 => '엔진공구',
        111000400004 => '배관공구',
        111000400005 => '용접공구',
        111000400006 => '절삭공구',
        111000400007 => '전동공구',
        111000400008 => '금형/공작기계',
        111000400009 => '목공구/목공기계',
        111000400010 => '수공구',
        111000400011 => '원예공구',
        111000400012 => '작업대/공구대',
        111000400013 => '사다리',
        111000400014 => '기타',
        111000500001 => '몰딩/경첩',
        111000500002 => '환기구/배수구',
        111000500003 => '욕실/화장실 철물',
        111000500004 => '열쇠/시건장치',
        111000500005 => '기타',
        111000500006 => '도어락/도어클로저',
        111000500007 => '손잡이',
        111000500008 => '건축 철물',
        111000500009 => '인테리어철물',
        111000500010 => '산업용철물',
        111000600001 => '냉각탑용약품',
        111000600002 => '수영장용 약품',
        111000600003 => '기계설비용 약품',
        111000600004 => '빌팅관리 약품',
        111000600005 => '소독약품',
        111000600006 => '기타',
        111000700001 => '영상케이블',
        111000700002 => '음향케이블',
        111000700003 => '전선/전화선',
        111000700004 => '소방케이블',
        111000700005 => '전력케이블',
        111000700006 => '통신케이블',
        111000700007 => '기타',
        111000800001 => '계전기기(계량기)',
        111000800002 => '충전지/축전지',
        111000800003 => '멀티탭/멀티코드',
        111000800004 => '차단기',
        111000800005 => '충전기',
        111000800006 => '건전지/전지',
        111000800007 => '스위치/콘센트',
        111000800008 => '플러그',
        111000800009 => '전자부품',
        111000800010 => '기타',
        111000900001 => '유성페인트',
        111000900002 => '수성페인트',
        111000900003 => '방수/엑폭시',
        111000900004 => '페인트보조제',
        111000900005 => '페인팅용품',
        111000900006 => '천연/친환경페인트',
        111000900007 => '자동차용페인트',
        111000900008 => '특수페인트',
        111000900009 => '기타',
        111001000001 => '네트워크',
        111001000002 => '네트워크부자재',
        111001000003 => 'CCTV',
        111001000004 => 'CCTV부자재',
        111001000005 => '기타',
        111001000006 => '경보장치',
        111001000007 => '블랙박스',
        111001000008 => 'RFID',
        111001100001 => '조경용품',
        111001100002 => '퇴비/비료',
        111001100003 => '제초제',
        111001100004 => '씨앗/종자',
        111001100005 => '묘목/나무',
        111001100006 => '기타',
        102000100001 => '초등영어교구',
        102000100002 => '중고등영어교구',
        102000100003 => '보드게임',
        102000100004 => '영어 S/W',
        102000100005 => '기타',
        102000200001 => '초등수학교구',
        102000200002 => '중고등수학교구',
        102000200003 => '보드게임',
        102000200004 => '수학 S/W',
        102000200005 => '기타',
        102000300001 => '기초과학교구',
        102000300002 => '광학기구',
        102000300003 => '계측기구',
        102000300004 => '실험기자재',
        102000300005 => '탐구실험키트',
        102000300006 => '표본/모형',
        102000300007 => '기타',
        102000400000 => '음악교구',
        102000400001 => '건반악기',
        102000400002 => '국악기',
        102000400003 => '관악기',
        102000400004 => '타악기',
        102000400005 => '현악기',
        102000400006 => '교재용악기',
        102000400007 => '기타',
        102000500001 => '스케치북/지류',
        102000500002 => '수채화용품',
        102000500003 => '유화/아크릴용품',
        102000500004 => '색연필/파스텔/목탄',
        102000500005 => '공예/조소/판화',
        102000500006 => '서예/동양화',
        102000500007 => '제도용품',
        102000500008 => '기타',
        102000600001 => '구기종목',
        102000600002 => '라켓종목',
        102000600003 => '육상용품',
        102000600004 => '민속놀이용품',
        102000600005 => '운동회용품',
        102000600006 => 'PAPS 장비',
        102000600007 => '운동복/운동화',
        102000600008 => '체육시설',
        102000600009 => '기타',
        102000600010 => '매트류',
        102000600011 => '네트/지주',
        102000600012 => '보드/작전판',
        102000700001 => '전자교탁',
        102000700002 => '전자칠판',
        102000700003 => '실물화상기',
        102000700004 => '기타',
        102000800001 => 'EBS',
        102000800002 => '보건/성교육/안전',
        102000800003 => '자연/환경/다큐',
        102000800004 => '영화/음반',
        102000800005 => '소프트웨어',
        102000800006 => '언어/외국어',
        102000800007 => '사회/경제',
        102000800008 => '문화/관광',
        102000800009 => '예술',
        102000800010 => '인성/도덕',
        102000800011 => '과학',
        102000800012 => '기타',
        102000900001 => '초등국어교구',
        102000900002 => '중고등국어교구',
        102000900003 => '보드게임',
        102000900004 => '국어 S/W',
        102000900005 => '기타',
        102001000001 => '초등사회교구',
        102001000002 => '중고등사회교구',
        102001000003 => '보드게임',
        102001000004 => '사회 S/W',
        102001000005 => '기타',
        102001100001 => '초등교구',
        102001100002 => '중고등교구',
        102001100003 => '보드게임',
        102001100004 => '기술,과정 S/W',
        102001100005 => '기타',
        102001200001 => '언어교구',
        102001200002 => '수학교구',
        102001200003 => '음악교구',
        102001200004 => '미술교구',
        102001200005 => '가베교구',
        102001200006 => '몬테소리',
        102001200007 => '퍼즐/레고',
        102001200008 => '체육교구',
        102001200009 => '기타',
        102001300001 => '언어치료',
        102001300002 => '작업치료',
        102001300003 => '인지치료',
        102001300004 => '감각통합치료',
        102001300005 => '심리치료',
        102001300006 => '운동치료',
        102001300007 => '미술/음악치료',
        102001300008 => '진단평가도구',
        102001300009 => '직업평가도구',
        102001300010 => '기타',
        110000100001 => '해열제',
        110000100002 => '진통제',
        110000100003 => '소염제',
        110000100004 => '각성제',
        110000100005 => '진훈제',
        110000100006 => '기타중추신경',
        110000200001 => '안과용제',
        110000200002 => '이비과용제',
        110000200003 => '기타감각기관',
        110000300001 => '흡인성알레르기',
        110000300002 => '약품알레르기',
        110000300003 => '식품알레르기',
        110000300004 => '접촉성알레르기',
        110000300005 => '물리적알레르기',
        110000300006 => '기타알레르기',
        110000400001 => '호흡촉진제',
        110000400002 => '진해거담제',
        110000400003 => '함소흡입제',
        110000400004 => '기타호흡기관약',
        110000500001 => '치과구강용약',
        110000500002 => '소화성궤양',
        110000500003 => '건위소화제',
        110000500004 => '제산제',
        110000500005 => '최토제/진토제',
        110000500006 => '이담제',
        110000500007 => '정장제',
        110000500008 => '기타소화기관',
        110000600001 => '남자',
        110000600002 => '여자',
        110000600003 => '통합',
        110000700001 => '살균소독제',
        110000700002 => '창상보호제',
        110000700003 => '화농성질환용제',
        110000700004 => '진통제',
        110000700005 => '소염제',
        110000700006 => '피부질환용제',
        110000700007 => '기타외피용약',
        110000800001 => '지혈제',
        110000800002 => '혈액대용제',
        110000800003 => '혈액응고저지제',
        110000800004 => '기타혈액체액용약',
        113000100001 => '0~3세',
        113000100002 => '4~7세',
        113000100003 => '기타',
        113000200001 => '초등1~2학년',
        113000200002 => '초등3~4학년',
        113000200003 => '초등5~6학년',
        113000200004 => '공통',
        113000200005 => '기타',
        113000200006 => '방송교재',
        113000200007 => '학습만화',
        113000300001 => '고전',
        113000300002 => '과학/수학',
        113000300003 => '역사/인물',
        113000300004 => '인문사회',
        113000300005 => '철학/논리',
        113000300006 => '예술/문화',
        113000300007 => '경제/자기계발',
        113000300008 => '학습법',
        113000300009 => '시험성공기',
        113000300010 => '논술',
        113000300011 => '건강',
        113000300012 => '진학/진로/유학',
        113000300013 => '에세이',
        113000300014 => '기타',
        113000300015 => '영어참고서',
        113000300016 => '수학참고서',
        113000300017 => '기타참고서',
        113000300018 => '문제집',
        113000300019 => '방송교재',
        113000400001 => '경상계열',
        113000400002 => '공학계열',
        113000400003 => '자연과학계열',
        113000400004 => '의약학간호계열',
        113000400005 => '농축산생명계열',
        113000400006 => '법학계열',
        113000400007 => '사범계열',
        113000400008 => '사회과학계열',
        113000400009 => '인문계열',
        113000400010 => '어문학계열',
        113000400011 => '사회학 일반',
        113000400012 => '과학일반',
        113000400013 => '예체능계열',
        113000400014 => '생활환경계열',
        113000400015 => '기타',
        113000500001 => '국어사전',
        113000500002 => '영어사전',
        113000500003 => '일본어사전',
        113000500004 => '중국어사전',
        113000500005 => '서양어',
        113000500006 => '동양어',
        113000500007 => '전문사전',
        113000500008 => '펜글씨교본',
        113000500009 => '기타',
        113000600001 => '인터넷/웹 개발',
        113000600002 => '프로그래밍',
        113000600003 => '운영체제(OS)',
        113000600004 => '네트워크/보안/모바일',
        113000600005 => '그래픽/멀티미디어',
        113000600006 => '데이터베이스',
        113000600007 => '엔지니어링',
        113000600008 => '오피스',
        113000600009 => '하드웨어',
        113000600010 => '게임/멀티미디어',
        113000600011 => '기타',
        113000700001 => '국내여행',
        113000700002 => '해외여행',
        113000700003 => '테마여행',
        113000700004 => '지도/지리',
        113000700005 => '유학/이민',
        113000700006 => '여행에세이',
        113000700007 => '기타',
        113000700008 => '정기간행물',
        113000800001 => '건강운동',
        113000800002 => '건강상식',
        113000800003 => '걷기/육상스포츠',
        113000800004 => '골프/공예',
        113000800005 => '구기',
        113000800006 => '낚시',
        113000800007 => '다이어트',
        113000800008 => '대체의학',
        113000800009 => '등산/캠핑',
        113000800010 => '무예/무술',
        113000800011 => '스포츠/레저 기타',
        113000800012 => '헬스/피트니스',
        113000800013 => '수영/수상스포츠',
        113000800014 => '원예',
        113000800015 => '질병치료와 예방',
        113000800016 => '기타',
        113000900001 => '요리',
        113000900002 => '결혼/가족/육아',
        113000900003 => '뜨개질/바느질/DIY',
        113000900004 => '술/음료/차',
        113000900005 => '조경',
        113000900006 => '주거/인테리어',
        113000900007 => '패션/뷰티',
        113000900008 => '기타',
        113001000001 => '기독교',
        113001000002 => '카톨릭',
        113001000003 => '불교',
        113001000004 => '세계의 종교',
        113001000005 => '역학',
        113001000006 => '명선.선',
        113001000007 => '종교일반',
        113001000008 => '기타',
        113001000009 => '동양철학',
        113001000010 => '서양철학',
        113001100001 => '경제/금융/회계/물류',
        113001100002 => '공무원수험서',
        113001100003 => '공인/주택관리사',
        113001100004 => '법/인문/사회/고시',
        113001100005 => '보건/위생/의학',
        113001100006 => '취업/상식/적성',
        113001100007 => '컴퓨터 활용능력',
        113001100008 => '한국어/한자/한국사',
        113001100009 => '어학관련자격증',
        113001100010 => '기타',
        113001100011 => '전기/전자',
        113001100012 => '가스/안전/환경',
        113001100013 => '건축/토목/기계',
        113001100014 => '운전/관광/기타',
        113001200001 => '예술',
        113001200002 => '미술',
        113001200003 => '음악',
        113001200004 => '영화',
        113001200005 => '연극',
        113001200006 => '무용',
        113001200007 => '건축',
        113001200008 => '사진',
        113001200009 => '문화',
        113001200010 => '디자인',
        113001200011 => '패션',
        113001200012 => '기타',
        113001200013 => '문학',
        113001200014 => '만화',
        113001300001 => '사회',
        113001300002 => '경제',
        113001300003 => '정치/외교',
        113001300004 => '경영/리더십',
        113001300005 => '마케팅/세일즈',
        113001300006 => '재테크/투자',
        113001300007 => '행정',
        113001300008 => '교육',
        113001300009 => '언론/미디어',
        113001300010 => '심리학',
        113001300011 => '생태/환경/지리',
        113001300012 => '이론/사상',
        113001300013 => '국방/군사',
        113001300014 => '기타',
        113001300015 => '법률',
        113001300016 => '한국사',
        113001300017 => '동양사',
        113001300018 => '서양사',
        113001300019 => '과학',
        113001300020 => '인문학',
        113001300021 => '의학/인체',
        112000100001 => '1000원이하',
        112000100002 => '5000원이하',
        112000100003 => '10000원이하',
        112000100004 => '15000원이하',
        112000100005 => '30000원이하',
        112000100006 => '50000원이하',
        112000100007 => '100000원이하',
        112000100008 => '100000원이상',
        112000200001 => '국기/간판',
        112000200002 => '상패/트로피',
        112000200003 => '의류/피복',
        112000200004 => '게임용품',
        112000200005 => '진행용품',
        112000200006 => '설치/장식용품',
        109000100001 => '농산물',
        109000100002 => '수산물',
        109000100003 => '축산물',
        109000100004 => '기타',
        109000200001 => '생수/음료',
        109000200002 => '커피/차',
        109000200003 => '소스',
        109000200004 => '통조림/캔',
        109000200005 => '즉석요리',
        109000200006 => '과자/간식류',
        109000200007 => '라면',
        109000200008 => '선물세트',
        109000200009 => '조미료',
        109000200010 => '가루/전분류',
        109000200011 => '건과류',
        109000200012 => '기름',
        109000200013 => '냉동식품',
        109000200014 => '기타',
        108000100001 => '가스/오븐레인지',
        108000100002 => '식기건조기/세척기',
        108000100003 => '정수기/냉온수기',
        108000100004 => '믹서기/녹즙기',
        108000100005 => '커피메이커',
        108000100006 => '보온/보냉고',
        108000100007 => '전기포트',
        108000100008 => '전기/압력밥솥',
        108000100009 => '싱크대/세정대',
        108000100010 => '제빙기',
        108000100011 => '운반카',
        108000100012 => '기타',
        108000100013 => '커터기/다지기',
        108000200001 => '소형식기',
        108000200002 => '냄비/펜',
        108000200003 => '조리기구',
        108000200004 => '물통/보관용기',
        108000200005 => '위생복',
        108000200006 => '장갑',
        108000200007 => '신발/장화',
        108000200008 => '일회용품',
        108000200009 => '기타',
        108000200010 => '행주/냅킨',
        108000200011 => '대형식기',
    );

    my %level3_reverse;
    for my $k ( keys %level3 ) {
        my $v = $level3{$k};
        $level3_reverse{$v} = [] unless $level3_reverse{$v};
        push @{ $level3_reverse{$v} }, $k;
    };

    return +{
        1       => \%level1,
        2       => \%level2,
        3       => \%level3,
        all     => { %level1, %level2, %level3 },
        reverse => {
            1   => { reverse %level1 },
            2   => { reverse %level2 },
            3   => \%level3_reverse,
        },
    };
}

sub search_company {
    my ( $self, $company, $query, $delay ) = @_;

    return unless $company;
    return unless $query;

    $delay //= 1;

    my $count = 100;

    my %params = (
        actionType         => 'MAIN_SEARCH',
        searchField        => 'COMPANY_NAME',
        searchQuery        => $company,
        searchRequery      => $query,
        startIndex         => 0,
        viewCount          => $count,
    );

    my @all_codes;
    my $last_start_index = $self->_get_last_start_index( \%params );
    for ( my $i = 0; $i <= $last_start_index; $i += $count ) {
        say STDERR "$i/$last_start_index";
        my @codes = $self->_get_product_codes({ %params, startIndex => $i });
        push @all_codes, @codes;

        sleep $delay if defined $delay;
    }

    return @all_codes;
}

sub _get_last_start_index {
    my ( $self, $params ) = @_;

    my %p              = %$params;
    my $search_query   = delete $p{searchQuery};
    my $search_requery = delete $p{searchRequery};

    my $url = $self->base_url . $self->category_url;
    $url .= '?' .  HTTP::Tiny->www_form_urlencode(\%p);
    $url .= '&searchQuery=';
    $url .= uri_escape( encode( "cp949", $search_query ) );
    $url .= '&searchRequery=';
    $url .= uri_escape( encode( "cp949", $search_requery ) );

    my $res = $self->http->get($url);
    my $dom = Mojo::DOM->new( decode( 'euc-kr', $res->{content} ) );

    my @pages;
    $dom->find('a')->each(sub {
        my $href = $_->attr('href');

        return unless $href =~ m/javascript:movePage\('delivery', '(\d+)'\)/;

        push @pages, $1;
    });

    my $last_start_index = max(@pages) || 0;

    return $last_start_index;
}

1;
