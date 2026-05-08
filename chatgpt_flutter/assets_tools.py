import os
import re
import csv
import subprocess

# Flutter项目相对脚本的路径
project_root_path = "."
# 定义输出扫描结果的文件名
csv_file = "未使用的资源.csv"


def scan_dart_files(directory):
    for root, dirs, files in os.walk(directory):
        for file in files:
            if file.endswith('.dart'):
                yield os.path.join(root, file)


def get_asset_references(file_path):
    with open(file_path, 'r') as f:
        content = f.read()
        p1 = r'(?:Image\.asset|AssetImage|Lottie\.asset)\(.*?\:\s*[\'\"](assets/[^\s\'\"]+)[\'\"]'
        p2 = r'(?:Image\.asset|AssetImage|Lottie\.asset)\(.*?[\'\"](assets/[^\s\'\"]+)[\'\"]'

        return re.findall(p1, content, re.DOTALL)+re.findall(p2, content, re.DOTALL)


def scan_assets(directory):
    for root, dirs, files in os.walk(directory):
        for file in files:
            if not file.startswith('.'):
                yield os.path.join('assets', os.path.relpath(os.path.join(root, file), directory))


def file_size(file_path):
    size_bytes = os.path.getsize(file_path)
    return round(size_bytes / 1024, 2)  # 将字节转换为KB，并四舍五入保留两位小数


def git_last_commit_info(file_path):
    relative_path = os.path.relpath(file_path, project_root_path)
    try:
        committer = subprocess.run(['git', 'log', '-1', '--pretty=format:%an', relative_path],
                                   cwd=project_root_path, capture_output=True, text=True, check=True).stdout.strip()
        commit_time = subprocess.run(['git', 'log', '-1', '--pretty=format:%ai', relative_path],
                                     cwd=project_root_path, capture_output=True, text=True, check=True).stdout.strip()
    except subprocess.CalledProcessError:
        return "未知", ""
    return committer, commit_time


def main():
    lib_path = os.path.join(project_root_path, 'lib')
    asset_path = os.path.join(project_root_path, 'assets')

    step = 1
    print(f"步骤 {step}: 查找 .dart 文件...")
    dart_files = list(scan_dart_files(lib_path))
    print(f'找到 {len(dart_files)} 个 .dart 文件.')

    step += 1
    print(f"步骤 {step}: 解析资源引用...")
    asset_references = set()
    file_iter = iter(dart_files)
    while True:
        try:
            file = next(file_iter)
            for ref in get_asset_references(file):
                asset_references.add(ref)
                if '3.0x' in ref:
                    temp = re.sub(r'/3\.0x/', '/', ref)
                    asset_references.add(temp)
        except StopIteration:
            break
    print(f'找到 {len(asset_references)} 个被引用的资源引用.')

    step += 1
    print(f"步骤 {step}: 查找资源文件...")
    assets = set(scan_assets(asset_path))
    print(f'找到 {len(assets)} 个资源文件.')

    step += 1
    print(f"步骤 {step}: 检查未使用的资源...")
    unused_assets = assets - asset_references
    remove_set = unused_assets.copy()
    asset_iter = iter(unused_assets)
    while True:
        try:
            ref = next(asset_iter)
            if '3.0x' in ref:
                file = re.sub(r'/3\.0x/', '/', ref)
                if file in asset_references:
                    remove_set.remove(ref)
        except StopIteration:
            break
    unused_assets = remove_set
    print(f'找到 {len(unused_assets)} 个未使用的资源.')

    step += 1
    print(f"步骤 {step}: 写入结果至 CSV 文件...")
    total_assets = len(unused_assets)
    with open(csv_file, 'w') as f:
        writer = csv.writer(f)
        writer.writerow(['资源', '大小 (KB)',  '最后提交时间', '最后提交人'])
        i = 0
        asset_iter = iter(unused_assets)
        while True:
            try:
                asset = next(asset_iter)
                file_path = os.path.join(project_root_path, asset)
                size = file_size(file_path)
                full_path = os.path.join(project_root_path, asset)
                committer, commit_time = git_last_commit_info(full_path)
                writer.writerow([asset, size, commit_time, committer])
                i += 1
                progress = i / total_assets * 100
                print(f'进度: {progress:.2f}%', end='\r')
            except StopIteration:
                break

    step += 1
    print(f"步骤 {step}: 完成！")


if __name__ == '__main__':
    main()