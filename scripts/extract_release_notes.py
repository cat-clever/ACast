#!/usr/bin/env python3.7
import os
import sys
import re

def extract_notes(tag, changelog_file="docs/RELEASE_NOTES.md", output_file="current_release_body.md"):
    # 1. 优先读取 docs/releases/<tag>.md
    specific_file = os.path.join("docs", "releases", f"{tag}.md")
    if os.path.isfile(specific_file):
        with open(specific_file, "r", encoding="utf-8") as f:
            content = f.read().strip()
        with open(output_file, "w", encoding="utf-8") as f:
            f.write(content + "\n")
        print(f"成功从 {specific_file} 读取当前版本发版说明！")
        return

    # 2. 从汇总文件 docs/RELEASE_NOTES.md 中提取
    if os.path.isfile(changelog_file):
        with open(changelog_file, "r", encoding="utf-8") as f:
            lines = f.readlines()

        v_clean = tag.lstrip("v")
        header_pattern = re.compile(rf"^#+\s+.*?(?:v?{re.escape(v_clean)}).*$", re.IGNORECASE)

        start_idx = -1
        end_idx = len(lines)

        for i, line in enumerate(lines):
            if start_idx == -1:
                if header_pattern.match(line.strip()):
                    start_idx = i
            else:
                # 遇到下一个同级或更高标题且包含其他版本时截断
                if re.match(r"^#+\s+(?:v?\d+\.\d+|ACast\s+v?\d+)", line.strip(), re.IGNORECASE):
                    end_idx = i
                    break

        if start_idx != -1:
            extracted = "".join(lines[start_idx:end_idx]).strip()
            # 移除结尾的分隔线
            extracted = re.sub(r"\n---\s*$", "", extracted).strip()
            with open(output_file, "w", encoding="utf-8") as f:
                f.write(extracted + "\n")
            print(f"成功从 {changelog_file} 中提取 {tag} 发版说明！")
            return

    # 3. 兜底默认说明
    fallback = f"# ACast {tag} 发布\n\n请参阅安装包列表下载体验。"
    with open(output_file, "w", encoding="utf-8") as f:
        f.write(fallback + "\n")
    print(f"未找到 {tag} 专用发版说明，使用基础说明。")

if __name__ == "__main__":
    current_tag = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("GITHUB_REF_NAME", "latest")
    extract_notes(current_tag)
