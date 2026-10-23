# Báo cáo kiểm thử nguồn media (100+ nguồn thật)

**Generated At**: `2026-10-21T16:57:35Z`  
**Tầng**: `quick`  
**Kết quả**: **136 PASS / 0 FAIL / 4 SKIP** (tổng 140)  

Mỗi nguồn được tải bằng **engine thật của app** (`MediaURLResolver` + `HTTPRangeDownloader`), mô hình **head + tail** nên file thưa có đúng kích thước nguồn và `ffprobe` đọc được cả `moov`/cues ở cuối. Kiểm chứng: magic byte (`FileTypeDetector`) + `ffprobe` stream + kích thước > 0.

## Tổng hợp

| Chỉ số | Giá trị |
|---|---|
| Tổng ca | 140 |
| PASS | 136 |
| FAIL | 0 |
| SKIP | 4 |
| Tỉ lệ PASS (không tính SKIP) | 100.0% |
| Host độc lập | 133 |
| Nguồn NSFW | 14 |

### Theo loại media

| Loại | Số ca | PASS | FAIL | SKIP |
|---|---|---|---|---|
| video | 78 | 78 | 0 | 0 |
| audio | 48 | 47 | 0 | 1 |
| image | 14 | 11 | 0 | 3 |

### Theo tag

| Tag | Số ca |
|---|---|
| legacy | 99 |
| api | 41 |
| nsfw | 14 |

## Chi tiết từng nguồn

| # | Host | Loại | Tag | URL (yêu cầu → thực tế) | Kích thước nguồn | Đã tải | Thời gian | Streams | Kết quả | Ghi chú |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | `23143.mc.tritondigital.com` | video | legacy | `https://23143.mc.tritondigital.com:443/OMNY_THEWILDWITHCHRISMORGAN2_P/` | 44.7 MB | 6.0 MB | 10.0s | audio+video | **PASS** | OK — mp3 [audio+video] |
| 2 | `24313.mc.tritondigital.com` | video | legacy | `https://24313.mc.tritondigital.com:443/OMNY_THISWEEKINGAMING_P/media-s` | 22.3 MB | 22.3 MB | 16.7s | audio+video | **PASS** | OK — mp3 [audio+video] |
| 3 | `24333.mc.tritondigital.com` | video | legacy | `https://24333.mc.tritondigital.com:443/OMNY_HISTORYUNPLUGGED_P/media-s` | 21.7 MB | 21.7 MB | 19.6s | audio+video | **PASS** | OK — mp3 [audio+video] |
| 4 | `26033.mc.tritondigital.com` | video | legacy | `https://26033.mc.tritondigital.com:443/OMNY_STUFFYOUMISSEDINHISTORYCLA` | 32.3 MB | 6.0 MB | 7.1s | audio+video | **PASS** | OK — mp3 [audio+video] |
| 5 | `26043.mc.tritondigital.com` | video | legacy | `https://26043.mc.tritondigital.com:443/OMNY_IAMALLINWITHSCOTTPATTERSON` | 12.8 MB | 12.8 MB | 14.1s | audio+video | **PASS** | OK — mp3 [audio+video] |
| 6 | `26053.mc.tritondigital.com` | video | legacy | `https://26053.mc.tritondigital.com:443/OMNY_BLOOMBERGTECHNOLOGY1_P/med` | 42.4 MB | 6.0 MB | 6.2s | audio+video | **PASS** | OK — mp3 [audio+video] |
| 7 | `26073.mc.tritondigital.com` | video | legacy | `https://26073.mc.tritondigital.com:443/OMNY_SHARPORSQUARE_P/media-sess` | 20.7 MB | 20.8 MB | 17.0s | audio+video | **PASS** | OK — mp3 [audio+video] |
| 8 | `26133.mc.tritondigital.com` | audio | legacy | `https://26133.mc.tritondigital.com:443/CBC_SKS_P/media-session/0379c5c` | 47.9 MB | 6.0 MB | 8.4s | audio+video | **PASS** | OK — mp3 [audio+video] |
| 9 | `26823.mc.tritondigital.com` | video | legacy | `https://26823.mc.tritondigital.com:443/OMNY_NFLTOTALACCESSTHELOCKERROO` | 39.6 MB | 6.0 MB | 10.4s | audio+video | **PASS** | OK — mp3 [audio+video] |
| 10 | `26833.mc.tritondigital.com` | video | legacy | `https://26833.mc.tritondigital.com:443/OMNY_THENIKKIGLASERPODCAST_P/me` | 73.3 MB | 6.0 MB | 8.6s | audio+video | **PASS** | OK — mp3 [audio+video] |
| 11 | `27083.mc.tritondigital.com` | video | legacy | `https://27083.mc.tritondigital.com:443/OMNY_NFLGOODMORNINGFOOTBALL_P/m` | 29.5 MB | 29.5 MB | 18.5s | audio+video | **PASS** | OK — mp3 [audio+video] |
| 12 | `27093.mc.tritondigital.com` | video | legacy | `https://27093.mc.tritondigital.com:443/OMNY_GILSARENA_P/media-session/` | 66.0 MB | 6.0 MB | 8.4s | audio+video | **PASS** | OK — mp3 [audio+video] |
| 13 | `27113.mc.tritondigital.com` | video | legacy | `https://27113.mc.tritondigital.com:443/OMNY_THEDANPATRICKSHOW_P/media-` | 47.8 MB | 6.0 MB | 9.9s | audio+video | **PASS** | OK — mp3 [audio+video] |
| 14 | `ads.julephosting.de` | video | legacy | `https://ads.julephosting.de/podcasts/431-true-crime-germany/217204-116` | 32.1 MB | 6.0 MB | 8.7s | audio+video | **PASS** | OK — mp3 [audio+video] |
| 15 | `afp-488641-injected.calisto.simplecastaudio.com` | audio | legacy | `https://afp-488641-injected.calisto.simplecastaudio.com/295461b6-267f-` | 32.6 MB | 6.0 MB | 2.2s | audio | **PASS** | OK — mp3 [audio] |
| 16 | `afp-928707-injected.calisto.simplecastaudio.com` | audio | legacy | `https://afp-928707-injected.calisto.simplecastaudio.com/666f737c-1d51-` | 22.2 MB | 22.2 MB | 13.5s | audio | **PASS** | OK — mp3 [audio] |
| 17 | `aod.cos.tx.xmcdn.com` | audio | legacy | `https://aod.cos.tx.xmcdn.com/storages/5707-audiofreehighqps/AB/56/GKwR` | 14.1 MB | 14.2 MB | 11.8s | audio | **PASS** | OK — mp4 [audio] |
| 18 | `atelier.flightcast.com` | audio | legacy | `https://atelier.flightcast.com/v2/audio/4669ca39dd6681bbbe75d3d7b35a7a` | 14.8 MB | 14.8 MB | 13.8s | audio | **PASS** | OK — mp3 [audio] |
| 19 | `audio3.redcircle.com` | audio | legacy | `https://audio3.redcircle.com/episodes/830c6343-8df2-4590-bfbc-77ae2a16` | 124.6 MB | 6.0 MB | 12.6s | audio | **PASS** | OK — mp3 [audio] |
| 20 | `audio.buzzsprout.com` | video | legacy | `https://audio.buzzsprout.com/1plifybcehwg0hmmmwwr9ajwf6sb?response-con` | 12.3 MB | 12.3 MB | 8.6s | audio+video | **PASS** | OK — mp3 [audio+video] |
| 21 | `audio.hbr.org` | video | legacy | `https://audio.hbr.org/on-leadership/20260618092617-HowLeadersCreatethe` | 28.0 MB | 28.0 MB | 16.8s | audio+video | **PASS** | OK — mp3 [audio+video] |
| 22 | `audio.podigee-cdn.net` | audio | legacy | `https://audio.podigee-cdn.net/537386-m-5ff207a739ebe948305fb7783e9fb8d` | 49.5 MB | 6.0 MB | 10.1s | audio+video | **PASS** | OK — mp3 [audio+video] |
| 23 | `open.live.bbc.co.uk` | video | legacy | `http://open.live.bbc.co.uk/mediaselector/6/redir/version/2.0/mediaset/` | 13.9 MB | 13.9 MB | 20.0s | audio+video | **PASS** | OK — mp3 [audio+video] |
| 24 | `dn800301.us.archive.org` | video | legacy | `https://dn800301.us.archive.org/0/items/tiger-bay-1959_202506/Tiger%20` | 364.8 MB | 6.0 MB | 6.8s | video+audio | **PASS** | OK — mp4 [video+audio] |
| 25 | `cdn.esahubble.org` | image | legacy | `https://cdn.esahubble.org/archives/images/large/heic1509a.jpg` | 17.8 MB | 17.8 MB | 14.0s | video | **PASS** | OK — jpg [video] |
| 26 | `cdn.podcast.co` | audio | legacy | `https://cdn.podcast.co/media/80473f45-01f6-4445-b798-662ef0196d96/fina` | 21.8 MB | 21.8 MB | 18.4s | audio | **PASS** | OK — mp3 [audio] |
| 27 | `cdn.simplecast.com` | audio | legacy | `https://cdn.simplecast.com/media/audio/transcoded/38cfda4e-d0b1-4985-b` | 36.1 MB | 6.0 MB | 5.5s | audio | **PASS** | OK — mp3 [audio] |
| 28 | `content.blubrry.com` | audio | legacy,nsfw | `https://content.blubrry.com/speakingofsex/HowToTryNewThingsInBed.mp3` | 38.8 MB | 6.0 MB | 5.4s | audio | **PASS** | OK — mp3 [audio] |
| 29 | `ia800607.us.archive.org` | video | legacy | `https://ia800607.us.archive.org/25/items/tiembla-y-titubea_1930/tiembl` | 1.42 GB | 6.0 MB | 6.1s | video+audio | **PASS** | OK — mp4 [video+audio] |
| 30 | `ia601005.us.archive.org` | video | legacy | `https://ia601005.us.archive.org/32/items/un-terceto-peculiar-1982/Un%2` | 500.7 MB | 6.0 MB | 9.5s | — | **PASS** | OK — mp4 (file thưa: ffprobe không đọc được stream) |
| 31 | `ia801407.us.archive.org` | video | legacy | `https://ia801407.us.archive.org/8/items/unacknowledged.-2017.308p/Unac` | 1.24 GB | 6.0 MB | 3.4s | video+audio | **PASS** | OK — mp4 [video+audio] |
| 32 | `prfx.byspotify.com` | audio | legacy | `https://prfx.byspotify.com/e/play.podtrac.com/npr-500005/npr.simplecas` | 4.6 MB | 4.6 MB | 9.6s | audio | **PASS** | OK — mp3 [audio] |
| 33 | `d2ffk1w24woq0d.cloudfront.net` | video | legacy | `https://d2ffk1w24woq0d.cloudfront.net/audio/661/8051/36731/8253552/28D` | 61.5 MB | 6.0 MB | 3.6s | audio+video | **PASS** | OK — mp3 [audio+video] |
| 34 | `d3ctxlq1ktw2nl.cloudfront.net` | audio | legacy | `https://d3ctxlq1ktw2nl.cloudfront.net/staging/2022-10-2/294628066-4410` | 76.0 MB | 6.0 MB | 2.5s | audio | **PASS** | OK — mp3 [audio] |
| 35 | `dai.transistor.fm` | video | legacy | `https://dai.transistor.fm/c1a9859b.mp3?s=78d14570ac96f572a3911c93971af` | 35.0 MB | 6.0 MB | 3.2s | audio+video | **PASS** | OK — mp3 [audio+video] |
| 36 | `dcs-cached.megaphone.fm` | video | legacy | `https://dcs-cached.megaphone.fm/WMHY8074761740.mp3?key=5d60bf4a7a5f323` | 61.3 MB | 6.0 MB | 9.6s | audio+video | **PASS** | OK — mp3 [audio+video] |
| 37 | `dcs.megaphone.fm` | video | legacy | `https://dcs.megaphone.fm/ESP5292655758.mp3?key=36f6af42e422f310545534b` | 23.2 MB | 23.2 MB | 24.8s | audio+video | **PASS** | OK — mp3 [audio+video] |
| 38 | `dcs-spotify.megaphone.fm` | video | legacy | `https://dcs-spotify.megaphone.fm/THRH4607164238.mp3?key=39a5907ba2d1e7` | 22.1 MB | 22.1 MB | 22.4s | audio+video | **PASS** | OK — mp3 [audio+video] |
| 39 | `delivery-edge.libsyn.com` | audio | legacy | `https://delivery-edge.libsyn.com/shows/84346/items/43067368/160-Listen` | 247.4 MB | 6.0 MB | 6.6s | audio | **PASS** | OK — mp3 [audio] |
| 40 | `archive.org` | video | api | `https://archive.org/download/nypd_s01e08_to-catch-a-hero/format=h.264` | 128.2 MB | 6.0 MB | 6.8s | video+audio | **PASS** | OK — mp4 [video+audio] |
| 41 | `cdn.arstechnica.net` | image | api | `https://cdn.arstechnica.net/wp-content/uploads/2022/05/caution-tape-10` | 69.1 KB | 72.0 KB | 1.6s | video | **PASS** | OK — jpg [video] |
| 42 | `dn600202.us.archive.org` | video | api | `https://dn600202.us.archive.org/0/items/speed-zone-1989-1080p-ai-upsca` | 1.01 GB | 6.0 MB | 6.6s | video+audio | **PASS** | OK — mp4 [video+audio] |
| 43 | `dn600203.us.archive.org` | video | api | `https://dn600203.us.archive.org/0/items/un-momento-muy-largo-1964/Un%2` | 421.1 MB | 6.0 MB | 6.9s | video+audio | **PASS** | OK — mp4 [video+audio] |
| 44 | `dn600204.us.archive.org` | video | api | `https://dn600204.us.archive.org/0/items/lp-473-pl_202403/LP473PL.m4v` | 1.98 GB | 6.0 MB | 7.2s | video+audio | **PASS** | OK — mp4 [video+audio] |
| 45 | `dn600205.us.archive.org` | video | api | `https://dn600205.us.archive.org/0/items/unutama-beni_movie/UNUTAMA%20B` | 2.06 GB | 6.0 MB | 6.9s | video+audio | **PASS** | OK — mp4 [video+audio] |
| 46 | `dn600301.us.archive.org` | video | api | `https://dn600301.us.archive.org/0/items/sevenler-kavusurmus_movie/Seve` | 348.9 MB | 6.0 MB | 5.4s | video+audio | **PASS** | OK — mp4 [video+audio] |
| 47 | `dn600302.us.archive.org` | video | api | `https://dn600302.us.archive.org/0/items/the-miracle-worker-1962/The.Mi` | 1.60 GB | 6.0 MB | 6.0s | video+audio | **PASS** | OK — mp4 [video+audio] |
| 48 | `ia803201.us.archive.org` | video | api,nsfw | `https://ia803201.us.archive.org/26/items/wenn-die-abendglocken-lauten_` | 2.55 GB | 6.0 MB | 3.5s | video+audio | **PASS** | OK — mp4 [video+audio] |
| 49 | `dn600308.us.archive.org` | video | api | `https://dn600308.us.archive.org/0/items/saygilar-bizden_movie/Sayg%C4%` | 422.0 MB | 6.0 MB | 5.4s | video+audio | **PASS** | OK — mp4 [video+audio] |
| 50 | `ia801605.us.archive.org` | video | api,nsfw | `https://ia801605.us.archive.org/29/items/vivah-2006-xvi-drip-mp-3/Viva` | 2.44 GB | 6.0 MB | 6.5s | audio+video | **PASS** | OK — mp4 [audio+video] |
| 51 | `dn601201.us.archive.org` | video | api | `https://dn601201.us.archive.org/0/items/hum-kaun-hai-2004-xvid-ac-3-e-` | 219.0 MB | 6.0 MB | 6.6s | video+audio | **PASS** | OK — mp4 [video+audio] |
| 52 | `dn601203.us.archive.org` | video | api | `https://dn601203.us.archive.org/0/items/up-all-night-at-the-drive-in-d` | 854.3 MB | 6.0 MB | 7.0s | video+audio | **PASS** | OK — mp4 [video+audio] |
| 53 | `dn601205.us.archive.org` | video | api | `https://dn601205.us.archive.org/0/items/ruzgar-zehra_movie/R%C3%BCzgar` | 439.7 MB | 6.0 MB | 6.0s | video+audio | **PASS** | OK — mp4 [video+audio] |
| 54 | `dn800300.us.archive.org` | video | api | `https://dn800300.us.archive.org/0/items/FAITHFUL_201401/FAITHFUL.mp4` | 147.1 MB | 6.0 MB | 6.8s | video+audio | **PASS** | OK — mp4 [video+audio] |
| 55 | `dn800303.us.archive.org` | video | api | `https://dn800303.us.archive.org/0/items/werewolf-of-london.-1935/WEREW` | 2.39 GB | 6.0 MB | 6.6s | video+audio | **PASS** | OK — mp4 [video+audio] |
| 56 | `dn800304.us.archive.org` | video | api | `https://dn800304.us.archive.org/0/items/IWillBeSeeingYou/IBSY.mp4` | 273.7 MB | 6.0 MB | 6.5s | video+audio | **PASS** | OK — mp4 [video+audio] |
| 57 | `dn800308.us.archive.org` | video | api | `https://dn800308.us.archive.org/0/items/mikrop_movie/Mikrop%20-%20Eski` | 413.8 MB | 6.0 MB | 6.5s | video+audio | **PASS** | OK — mp4 [video+audio] |
| 58 | `dn800309.us.archive.org` | video | api | `https://dn800309.us.archive.org/0/items/ungekusst-soll-man-nicht-schla` | 234.0 MB | 6.0 MB | 6.7s | video+audio | **PASS** | OK — mp4 [video+audio] |
| 59 | `dn801201.us.archive.org` | video | api | `https://dn801201.us.archive.org/0/items/Frankenstein1974-BorisLugosi/F` | 779.0 MB | 6.0 MB | 5.8s | audio+video | **PASS** | OK — mp4 [audio+video] |
| 60 | `dn801202.us.archive.org` | video | api | `https://dn801202.us.archive.org/0/items/unholythree4k/unholythree4k.ia` | 2.76 GB | 6.0 MB | 5.3s | video+audio | **PASS** | OK — mp4 [video+audio] |
| 61 | `dn801203.us.archive.org` | video | api | `https://dn801203.us.archive.org/0/items/people-of-the-cumberland-1937-` | 1.51 GB | 6.0 MB | 7.2s | video+audio | **PASS** | OK — mp4 [video+audio] |
| 62 | `dn801204.us.archive.org` | video | api | `https://dn801204.us.archive.org/0/items/jesus-film-toma-language/JESUS` | 198.2 MB | 6.0 MB | 5.4s | video+audio | **PASS** | OK — mp4 [video+audio] |
| 63 | `dn801205.us.archive.org` | audio | api | `https://dn801205.us.archive.org/0/items/Battle.of.Midway.1942/Battle.o` | 12.5 MB | 12.5 MB | 7.5s | audio | **PASS** | OK — mp3 [audio] |
| 64 | `dn801208.us.archive.org` | video | api | `https://dn801208.us.archive.org/0/items/jesus-film-tamajeg-tahoua-lang` | 188.5 MB | 6.0 MB | 5.6s | video+audio | **PASS** | OK — mp4 [video+audio] |
| 65 | `dn801209.us.archive.org` | audio | api | `https://dn801209.us.archive.org/0/items/Painting_ShortVersion/1996Pain` | 7.6 MB | 7.6 MB | 6.1s | audio | **PASS** | OK — mp3 [audio] |
| 66 | `files.yande.re` | image | api,nsfw | `https://files.yande.re/image/6395cd887c8c1f60d84fbd3ddf57b98e/yande.re` | 6.6 MB | 6.6 MB | 6.2s | video | **PASS** | OK — jpg [video] |
| 67 | `ia801509.us.archive.org` | video | api | `https://ia801509.us.archive.org/9/items/veergati-1995-dv-drip-x-264-es` | 1.24 GB | 6.0 MB | 5.8s | — | **PASS** | OK — mp4 (file thưa: ffprobe không đọc được stream) |
| 68 | `—` | audio | api | `https://i.guim.co.uk/img/media/5a1fa2211f8394d63f3fcf24e563458a5818c40` | 0 B | 0 B | 0.7s | — | **SKIP** | Probe thất bại (URL chết hoặc cần đăng nhập) |
| 69 | `ia600701.us.archive.org` | video | api | `https://ia600701.us.archive.org/35/items/the-mysterious-island-1929/Th` | 312.7 MB | 6.0 MB | 6.8s | video+audio | **PASS** | OK — mp4 [video+audio] |
| 70 | `ia800701.us.archive.org` | video | api | `https://ia800701.us.archive.org/5/items/un-toque-diferente-1977/Un%20t` | 572.4 MB | 6.0 MB | 6.5s | — | **PASS** | OK — mp4 (file thưa: ffprobe không đọc được stream) |
| 71 | `ia800807.us.archive.org` | video | api | `https://ia800807.us.archive.org/9/items/que-es-el-otono-1977/Que%20es%` | 556.2 MB | 6.0 MB | 6.7s | — | **PASS** | OK — mp4 (file thưa: ffprobe không đọc được stream) |
| 72 | `ia800903.us.archive.org` | video | api | `https://ia800903.us.archive.org/4/items/sandvich-2004-dvdrip-tikris/Sa` | 444.6 MB | 6.0 MB | 7.9s | video | **PASS** | OK — mp4 [video] |
| 73 | `ia903107.us.archive.org` | video | api | `https://ia903107.us.archive.org/10/items/una-mujer-de-la-calle-1939/Un` | 1.92 GB | 6.0 MB | 7.1s | video+audio | **PASS** | OK — mp4 [video+audio] |
| 74 | `images-assets.nasa.gov` | image | api | `https://images-assets.nasa.gov/image/PIA12817/PIA12817~small.jpg` | 12.0 KB | 12.0 KB | 1.0s | video | **PASS** | OK — jpg [video] |
| 75 | `konachan.net` | image | api,nsfw | `https://konachan.net/image/cb0405e90a962078d985c05846114bfa/Konachan.c` | 2.5 MB | 2.5 MB | 1.4s | video | **PASS** | OK — png [video] |
| 76 | `konachan.net` | image | api,nsfw | `https://konachan.net/image/5f0a783ef8b540790071be048668ba90/Konachan.c` | 26.8 MB | 26.8 MB | 11.1s | video | **PASS** | OK — png [video] |
| 77 | `prfx.byspotify.com` | audio | api | `https://prfx.byspotify.com/e/play.podtrac.com/npr-500005/npr.simplecas` | 4.6 MB | 4.6 MB | 14.2s | audio | **PASS** | OK — mp3 [audio] |
| 78 | `prfx.byspotify.com` | audio | api | `https://prfx.byspotify.com/e/play.podtrac.com/npr-500005/npr.simplecas` | 4.6 MB | 4.6 MB | 8.4s | audio | **PASS** | OK — mp3 [audio] |
| 79 | `—` | image | api,nsfw | `https://static1.e621.net/data/c1/eb/c1ebf02bdc1439a9…` → `https://static1.e621.net/data/06/f4/06f422a30c8d75eb…` | 0 B | 0 B | 84.4s | — | **SKIP** | Probe thất bại (URL chết hoặc cần đăng nhập) |
| 80 | `—` | image | api,nsfw | `https://static1.e621.net/data/01/0a/010ac3df6b32e47d…` → `https://static1.e621.net/data/b8/1b/b81bf2e33ff1c8f2…` | 0 B | 0 B | 84.4s | — | **SKIP** | Probe thất bại (URL chết hoặc cần đăng nhập) |
| 81 | `dn600209.us.archive.org` | video | legacy,nsfw | `https://dn600209.us.archive.org/0/items/hborealsex/Real%20Sex%2001%20(` | 807.1 MB | 6.0 MB | 6.2s | — | **PASS** | OK — mp4 (file thưa: ffprobe không đọc được stream) |
| 82 | `dovetail-cdn.prxu.org` | audio | legacy | `https://dovetail-cdn.prxu.org/usw2/93/9ea8a958-7aa2-4aa4-83bc-f82c7614` | 38.8 MB | 6.0 MB | 4.6s | audio | **PASS** | OK — mp3 [audio] |
| 83 | `dowjones.simplecastaudio.com` | audio | legacy | `https://dowjones.simplecastaudio.com/3d1c8b0a-4b6d-4ea9-a455-ab1adaa7e` | 16.0 MB | 16.0 MB | 13.2s | audio | **PASS** | OK — mp3 [audio] |
| 84 | `dq0hsqwjhea1.cloudfront.net` | audio | legacy | `https://dq0hsqwjhea1.cloudfront.net/2026.10.01-SkyTour.mp3` | 10.0 MB | 10.0 MB | 6.5s | audio | **PASS** | OK — mp3 [audio] |
| 85 | `ed.podomatic.net` | video | legacy | `https://ed.podomatic.net/e/doggiedelic3.podomatic.com/2019-02-05T22_30` | 81.8 MB | 6.0 MB | 3.9s | audio+video | **PASS** | OK — mp3 [audio+video] |
| 86 | `episodes.castos.com` | audio | legacy | `https://episodes.castos.com/67e2bdbcd47fe8-69973996/2642116/c1e-nq972i` | 32.1 MB | 6.0 MB | 3.5s | audio | **PASS** | OK — mp3 [audio] |
| 87 | `feeds.soundcloud.com` | audio | legacy | `https://feeds.soundcloud.com/stream/306945684-houstonsymphony-mussorgs` | 144.0 MB | 6.0 MB | 7.7s | audio | **PASS** | OK — mp3 [audio] |
| 88 | `prfx.byspotify.com` | audio | legacy | `https://prfx.byspotify.com/e/play.podtrac.com/npr-510312/npr.simplecas` | 33.4 MB | 6.0 MB | 11.2s | audio | **PASS** | OK — mp3 [audio] |
| 89 | `files.hubhopper.com` | audio | legacy | `https://files.hubhopper.com/podcast/309012/episode/16519660/calm-music` | 46.5 MB | 6.0 MB | 2.5s | audio | **PASS** | OK — mp3 [audio] |
| 90 | `files.yande.re` | image | legacy,nsfw | `https://files.yande.re/image/82e8de9d1624177e14c2b084594d464b/yande.re` | 33.5 MB | 6.0 MB | 6.3s | video | **PASS** | OK — png [video] |
| 91 | `goethe-institut.stationista.com` | video | legacy | `https://goethe-institut.stationista.com/fd/63ef5908f5fbcd3a7b578efd/au` | 18.6 MB | 18.6 MB | 16.4s | audio+video | **PASS** | OK — mp3 [audio+video] |
| 92 | `hosting-media.riverside.com` | audio | legacy | `https://hosting-media.riverside.com/media/clips/6ab654dd5648eafb144729` | 87.4 MB | 6.0 MB | 2.4s | audio | **PASS** | OK — mp3 [audio] |
| 93 | `images-assets.nasa.gov` | video | legacy | `https://images-assets.nasa.gov/video/GSFC_20140421_EarthOrbit_m11525/G` | 244.3 MB | 6.0 MB | 6.4s | video+audio+data | **PASS** | OK — mp4 [video+audio+data] |
| 94 | `images.unsplash.com` | image | legacy | `https://images.unsplash.com/photo-1579783900882-c0d3dad7b119?q=100&w=6` | 20.5 MB | 20.5 MB | 10.5s | video | **PASS** | OK — jpg [video] |
| 95 | `injector.simplecastaudio.com` | audio | legacy | `https://injector.simplecastaudio.com/100c7b5e-9197-421c-ab58-cff1ab365` | 40.9 MB | 6.0 MB | 9.0s | audio | **PASS** | OK — mp3 [audio] |
| 96 | `kdrt.org` | audio | legacy | `https://kdrt.org/sites/default/files/podcasts/Jazz%20After%20Dark%20Oc` | 69.7 MB | 6.0 MB | 8.9s | audio | **PASS** | OK — mp3 [audio] |
| 97 | `konachan.net` | image | legacy,nsfw | `https://konachan.net/image/df596d3c06c9180448e284624104ddee/Konachan.c` | 35.0 MB | 6.0 MB | 2.8s | video | **PASS** | OK — png [video] |
| 98 | `kpbs-od.streamguys1.com` | audio | legacy | `https://kpbs-od.streamguys1.com/kpbs_podcasts/cinema_junkie/2026100815` | 32.3 MB | 6.0 MB | 7.8s | audio | **PASS** | OK — mp3 [audio] |
| 99 | `lcdn.letscast.fm` | video | legacy | `https://lcdn.letscast.fm/media/podcast/0f1f2c89/episode/96d21b36.mp3?t` | 33.0 MB | 6.0 MB | 7.1s | audio+video | **PASS** | OK — mp3 [audio+video] |
| 100 | `media.byub.org` | audio | legacy | `https://media.byub.org/bc2c9567-fabd-4b8a-ace8-5e0d6a5b6510/MA027208.m` | 14.1 MB | 14.1 MB | 7.9s | audio+video | **PASS** | OK — mp3 [audio+video] |
| 101 | `media.fidelity.com` | audio | legacy | `https://media.fidelity.com/assets/Fidelity.com_VMS/679/378/49962_Marke` | 65.2 MB | 6.0 MB | 5.3s | audio | **PASS** | OK — mp3 [audio] |
| 102 | `media.podcasts.ox.ac.uk` | video | legacy | `https://media.podcasts.ox.ac.uk/physics/physics-public/2025-05-08-phys` | 1.10 GB | 6.0 MB | 7.5s | audio+video | **PASS** | OK — mp4 [audio+video] |
| 103 | `media.redcircle.com` | audio | legacy | `https://media.redcircle.com/2024/3/9/16/87dcbf44-7f6e-44d0-9bdb-4b923f` | 79.7 MB | 6.0 MB | 3.0s | audio | **PASS** | OK — mp3 [audio] |
| 104 | `media.xiph.org` | video | legacy | `https://media.xiph.org/tearsofsteel/tears_of_steel_1080p.webm` | 544.9 MB | 6.0 MB | 7.9s | video+audio | **PASS** | OK — mkv [video+audio] |
| 105 | `media.xyzcdn.net` | audio | legacy | `https://media.xyzcdn.net/5fa6109983c34e85dd2ac8ee/lrNySSPtABa0Tl3rejdl` | 128.8 MB | 6.0 MB | 5.0s | audio | **PASS** | OK — mp4 [audio] |
| 106 | `mirrors.dotsrc.org` | video | legacy | `https://mirrors.dotsrc.org/cdn.media.ccc.de/events/privacyweek/2018/h2` | 975.3 MB | 6.0 MB | 6.8s | video+audio | **PASS** | OK — mp4 [video+audio] |
| 107 | `nbcnews.simplecastaudio.com` | audio | legacy | `https://nbcnews.simplecastaudio.com/94e25754-e86b-45c4-823a-db69b4df29` | 37.4 MB | 6.0 MB | 9.2s | audio | **PASS** | OK — mp3 [audio] |
| 108 | `ndr-podcast.ard-mcdn.de` | audio | legacy | `https://ndr-podcast.ard-mcdn.de/progressive/2026/0929/AU-20260929-1912` | 71.3 MB | 6.0 MB | 9.3s | audio | **PASS** | OK — mp3 [audio] |
| 109 | `npr.simplecastaudio.com` | audio | legacy | `https://npr.simplecastaudio.com/d52bee4a-b10a-40f8-9417-45064e6b8632/e` | 27.9 MB | 27.9 MB | 17.7s | audio | **PASS** | OK — mp3 [audio] |
| 110 | `pipe-stream.barstoolsports.com` | audio | legacy | `https://pipe-stream.barstoolsports.com/barstool-sports/pardon-my-take/` | 130.8 MB | 6.0 MB | 4.8s | audio | **PASS** | OK — mp3 [audio] |
| 111 | `pmd.cdn.turner.com` | video | legacy | `http://pmd.cdn.turner.com/cnn/big/cnn10/2020/11/09/ten-1111.cnn_347066` | 90.0 MB | 6.0 MB | 3.1s | video+audio | **PASS** | OK — mp4 [video+audio] |
| 112 | `podcast-mp3.dradio.de` | audio | legacy | `https://podcast-mp3.dradio.de/podcast/2026/10/11/midterms_in_den_usa_d` | 27.9 MB | 27.9 MB | 23.4s | audio | **PASS** | OK — mp3 [audio] |
| 113 | `podcasts-2.feedpress.com` | audio | legacy | `https://podcasts-2.feedpress.com/23971/Discovering%20Jazz%20-383-%20Ja` | 55.0 MB | 6.0 MB | 7.9s | audio | **PASS** | OK — mp3 [audio] |
| 114 | `podcasts.captivate.fm` | audio | legacy | `https://podcasts.captivate.fm/b1e10584-ef12-4a62-be38-36b46710da62.mp3` | 161.5 MB | 6.0 MB | 2.4s | audio | **PASS** | OK — mp3 [audio] |
| 115 | `podcasts.tfm.co.jp` | audio | legacy | `https://podcasts.tfm.co.jp/podcasts/tokyo/future/future2434_0323.mp3` | 16.3 MB | 16.3 MB | 12.8s | audio | **PASS** | OK — mp3 [audio] |
| 116 | `rogers.simplecastaudio.com` | audio | legacy | `https://rogers.simplecastaudio.com/5dd47c7a-c274-43dd-9323-630d0e8a2bc` | 51.8 MB | 6.0 MB | 3.3s | audio | **PASS** | OK — mp3 [audio] |
| 117 | `tracking.swap.fm` | audio | legacy | `https://tracking.swap.fm/track/XvDEoI11TR00olTUO8US/prfx.byspotify.com` | 30.3 MB | 30.3 MB | 20.5s | audio | **PASS** | OK — mp3 [audio] |
| 118 | `ia601002.us.archive.org` | video | legacy | `https://ia601002.us.archive.org/21/items/jaagruti-1992-dv-drip-x-264-e` | 396.1 MB | 6.0 MB | 6.9s | video+audio | **PASS** | OK — mp4 [video+audio] |
| 119 | `ia601900.us.archive.org` | video | legacy | `https://ia601900.us.archive.org/6/items/battle.-beyond.the.-sun.-1962/` | 400.8 MB | 6.0 MB | 5.5s | video+audio | **PASS** | OK — mp4 [video+audio] |
| 120 | `ia801506.us.archive.org` | video | legacy | `https://ia801506.us.archive.org/12/items/tomatos-another-day_1930/toma` | 195.3 MB | 6.0 MB | 5.5s | video+audio | **PASS** | OK — mp4 [video+audio] |
| 121 | `dn800305.us.archive.org` | video | legacy | `https://dn800305.us.archive.org/0/items/up-in-the-world/Up%20in%20the%` | 6.16 GB | 6.0 MB | 6.7s | audio+video+video | **PASS** | OK — mp4 [audio+video+video] |
| 122 | `www.podtrac.com` | audio | legacy | `https://www.podtrac.com/pts/redirect.mp3/dovetail.prxu.org/7057/88c4d7` | 81.6 MB | 6.0 MB | 9.7s | audio+video | **PASS** | OK — mp3 [audio+video] |
| 123 | `dn800203.us.archive.org` | video | legacy | `https://dn800203.us.archive.org/0/items/chinese-roulette/chinese%20rou` | 207.8 MB | 6.0 MB | 6.4s | video+audio | **PASS** | OK — mp4 [video+audio] |
| 124 | `dn600206.us.archive.org` | audio | legacy | `https://dn600206.us.archive.org/0/items/1940-Achtung-Feind-hoert-mit/1` | 61.0 MB | 6.0 MB | 5.9s | audio | **PASS** | OK — mp3 [audio] |
| 125 | `ia601406.us.archive.org` | video | legacy | `https://ia601406.us.archive.org/14/items/video-1_20251124/video%20%281` | 546.0 MB | 6.0 MB | 5.1s | video+audio | **PASS** | OK — mp4 [video+audio] |
| 126 | `s3.amazonaws.com` | audio | legacy | `http://s3.amazonaws.com/dlc.footytips.com.au/podcast/pti/PTI_Australia` | 21.0 MB | 21.0 MB | 17.9s | audio | **PASS** | OK — mp3 [audio] |
| 127 | `safebooru.org` | image | legacy,nsfw | `https://safebooru.org/images/3923/475b96819e9c27dc904053918e0883e9b057` | 20.6 MB | 20.6 MB | 9.5s | video | **PASS** | OK — png [video] |
| 128 | `samplelib.com` | video | legacy | `https://samplelib.com/mp4/sample-30s.mp4` | 20.7 MB | 20.7 MB | 18.0s | video+audio | **PASS** | OK — mp4 [video+audio] |
| 129 | `—` | image | legacy,nsfw | `https://static1.e621.net/data/e0/7b/e07b45fe09832842…` → `https://static1.e621.net/data/b8/1b/b81bf2e33ff1c8f2…` | 0 B | 0 B | 84.4s | — | **SKIP** | Probe thất bại (URL chết hoặc cần đăng nhập) |
| 130 | `ia600908.us.archive.org` | video | legacy | `https://ia600908.us.archive.org/14/items/twilight-people-1972_202508/T` | 53.6 MB | 6.0 MB | 3.3s | video | **PASS** | OK — mp4 [video] |
| 131 | `stitcher.simplecastaudio.com` | audio | legacy | `https://stitcher.simplecastaudio.com/8b62332a-56b8-4d25-b175-1e588b078` | 55.0 MB | 6.0 MB | 2.4s | audio | **PASS** | OK — mp3 [audio] |
| 132 | `storage.pinecast.net` | video | legacy | `https://storage.pinecast.net/podcasts/c7fedd7c-b05f-4591-94b7-6fc70e98` | 25.8 MB | 25.8 MB | 12.6s | audio+video | **PASS** | OK — mp3 [audio+video] |
| 133 | `dn801200.us.archive.org` | video | legacy | `https://dn801200.us.archive.org/0/items/till-the-clouds-roll-by-1946_2` | 811.0 MB | 6.0 MB | 5.1s | — | **PASS** | OK — mp4 (file thưa: ffprobe không đọc được stream) |
| 134 | `twit.cachefly.net` | video | legacy | `https://twit.cachefly.net/video/omgcraft/omgcraft0198/omgcraft0198_h26` | 442.0 MB | 6.0 MB | 5.9s | video+audio | **PASS** | OK — mp4 [video+audio] |
| 135 | `upload.wikimedia.org` | video | legacy | `https://upload.wikimedia.org/wikipedia/commons/transcoded/c/c0/Big_Buc` | 286.5 MB | 6.0 MB | 5.9s | video+audio | **PASS** | OK — mkv [video+audio] |
| 136 | `vjs.zencdn.net` | video | legacy | `https://vjs.zencdn.net/v/oceans.mp4` | 21.9 MB | 21.9 MB | 8.3s | video+audio | **PASS** | OK — mp4 [video+audio] |
| 137 | `www.astronomy.ohio-state.edu` | audio | legacy | `https://www.astronomy.ohio-state.edu/pogge.1/Ast162/Audio/Lect05.mp3` | 14.1 MB | 14.1 MB | 17.7s | audio | **PASS** | OK — mp3 [audio] |
| 138 | `www.deservewhatyouwant.net` | video | legacy,nsfw | `https://www.deservewhatyouwant.net/podcasts/episode91_our_favorite_ons` | 32.4 MB | 6.0 MB | 3.9s | audio+video | **PASS** | OK — mp3 [audio+video] |
| 139 | `www.eso.org` | image | legacy | `https://www.eso.org/public/archives/images/original/eso1907a.tif` | 183.4 MB | 6.0 MB | 8.2s | video | **PASS** | OK — tif [video] |
| 140 | `www.learningcontainer.com` | video | legacy | `https://www.learningcontainer.com/wp-content/uploads/2020/05/sample-mp` | 10.1 MB | 10.1 MB | 7.0s | video+audio | **PASS** | OK — mp4 [video+audio] |

## Ca SKIP (nguồn không dùng được — không tính là PASS)

### Theo họ host

| Họ host | Số ca SKIP |
|---|---|
| `e621.net` | 3 |
| `co.uk` | 1 |

> Nhiều ca SKIP cùng lúc thường do **một dịch vụ CDN không phản hồi** (mạng chặn/rate-limit), không phải lỗi của app. Có thể chạy lại sau, hoặc bỏ qua nhóm đó bằng `--exclude-host <tên miền>`.

| # | Host | Lý do |
|---|---|---|
| `i.guim.co.uk` | disc_i_guim_co_uk_0d4c2cc8 | Probe thất bại (URL chết hoặc cần đăng nhập) |
| `static1.e621.net` | disc_static1_e621_net_4fe3f608 | Probe thất bại (URL chết hoặc cần đăng nhập) |
| `static1.e621.net` | disc_static1_e621_net_cd1b89cc | Probe thất bại (URL chết hoặc cần đăng nhập) |
| `static1.e621.net` | static1_e621_net_13 | Probe thất bại (URL chết hoặc cần đăng nhập) |

## Ghi chú

- `SKIP` = nguồn không truy cập được (URL hết hạn, cần đăng nhập, bị policy chặn) — **không tính là PASS**.
- Nguồn NSFW được đánh dấu bằng tag `nsfw`; chạy `--exclude-tag nsfw` để không chạy/nhìn thấy nhóm này.
- Bộ test không bao giờ gửi cookie/tài khoản: mục `access: requires-auth` bị bỏ qua.
- Danh sách nguồn: `scripts/media_sources_100.json`; làm mới: `python3 scripts/refresh_media_sources.py refresh --update-config`.

