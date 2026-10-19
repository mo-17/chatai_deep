#!/usr/bin/env python3
"""从 APK release.json 更新官网版本和四种架构入口。"""
import argparse
import json
import pathlib
import re
from html import escape


def prepare(manifest, site):
    release = json.loads(manifest.read_text())
    artifacts = release['artifacts']
    primary = artifacts['arm64-v8a']
    version = release['versionName']
    build = release['versionCode']
    url = escape(primary['url'], quote=True)
    links = []
    for abi, label in [('armeabi-v7a','32 位 Android'),('x86_64','x86_64 模拟器/设备'),('universal','通用包（不确定架构时选择）')]:
        item = release if abi == 'universal' else artifacts[abi]
        links.append(f'<li><a href="{escape(item["url"], quote=True)}" download>{label} · {item["bytes"]/1000000:.1f} MB</a></li>')
    article = f'''<article class="download-card android"><div class="platform-top"><span class="platform-icon" aria-hidden="true">↧</span><span class="release-badge">体验版</span></div><h3>Android</h3><p>适用于 Android 7.0 及以上</p><a class="button primary download-link" href="{url}" download>下载 Android 64 位 APK <span aria-hidden="true">↓</span></a><div class="release-info">v{version} · Build {build} <span>{primary['bytes']/1000000:.1f} MB</span></div><p class="release-notice">当前为测试签名安装包，尚未完成真机验收。离线语音模型可在客户端按需下载。</p><a class="checksum-link" href="{url}.sha256" download>下载 SHA-256 校验文件 <span aria-hidden="true">↗</span></a><details><summary>其它架构与通用包</summary><ul>{''.join(links)}</ul></details></article>'''
    html = site/'index.html'
    text, count = re.subn(r'<article class="download-card android">.*?</article>', lambda _: article, html.read_text(), count=1, flags=re.S)
    if count != 1:
        raise ValueError('Android download section not found')
    html.write_text(text)
    data = {'product':'艾普','version':version,'build':build,'channel':'preview','platform':'android','minAndroidSdk':24,'signing':'debug','deviceAcceptance':False,
            'bytes':release['bytes'],'url':release['url'],'sha256':release['sha256'],'backendOrigin':'https://kushui.shop','artifacts':artifacts}
    (site/'site-assets/release.json').write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n')
    print(f'Website metadata prepared: {version}+{build}')


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest',required=True,type=pathlib.Path)
    parser.add_argument('--website',required=True,type=pathlib.Path)
    args=parser.parse_args()
    prepare(args.manifest,args.website)
