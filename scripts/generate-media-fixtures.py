"""Generate tiny, original movies with subtitle tracks and our own font fixtures.
Run: uv run --with imageio-ffmpeg scripts/generate-media-fixtures.py
FFmpeg is only a fixture-generation tool, not an application dependency.
"""
from pathlib import Path
import subprocess
import tempfile
import imageio_ffmpeg

root = Path(__file__).resolve().parent.parent
fixtures = root / 'Tests/SubFontCoreTests/Fixtures'
ffmpeg = imageio_ffmpeg.get_ffmpeg_exe()

def run(*arguments):
    subprocess.run([ffmpeg, '-hide_banner', '-loglevel', 'error', '-y', *map(str, arguments)], check=True)

with tempfile.TemporaryDirectory(prefix='subfont-media-fixtures-') as temporary:
    work = Path(temporary)
    ass = work / 'primary.ass'
    ass.write_text('''[Script Info]
ScriptType: v4.00+
PlayResX: 320
PlayResY: 180
[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,SubFont Test Fixture,24,&H00FFFFFF,&H00FFFFFF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,1,0,2,10,10,10,1
Style: Unused,Do Not Load This Font,24,&H00FFFFFF,&H00FFFFFF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,1,0,2,10,10,10,1
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.00,0:00:01.00,Default,,0,0,0,,A{\\fnSubFont CFF Fixture}A, comma
''', encoding='utf-8')
    second = work / 'second.ass'
    second.write_text(ass.read_text().replace('SubFont Test Fixture', 'SubFont Second Fixture').replace('A{\\fnSubFont CFF Fixture}A, comma', 'A'), encoding='utf-8')
    run('-f', 'lavfi', '-i', 'color=c=black:s=320x180:r=1:d=1', '-i', ass, '-i', second,
        '-map', '0:v', '-map', '1:s', '-map', '2:s', '-c:v', 'mpeg4', '-c:s', 'copy',
        '-attach', fixtures / 'SubFontTest-Regular.ttf', '-metadata:s:t:0', 'mimetype=font/ttf',
        '-metadata:s:t:0', 'filename=../../outside.ttf',
        '-attach', fixtures / 'SubFontTest-CFF.otf', '-metadata:s:t:1', 'mimetype=font/otf',
        '-metadata:s:t:1', 'filename=Fixture.otf',
        '-attach', fixtures / 'SubFontTest-Second.ttf', '-metadata:s:t:2', 'mimetype=font/ttf',
        '-metadata:s:t:2', 'filename=Second.ttf',
        fixtures / 'EmbeddedSubtitles.mkv')
    run('-f', 'lavfi', '-i', 'color=c=black:s=320x180:r=1:d=1', '-i', second,
        '-map', '0:v', '-map', '1:s', '-c:v', 'mpeg4', '-c:s', 'mov_text',
        fixtures / 'TimedText.mp4')
    styled = work / 'styled.ass'
    default_style = next(line for line in ass.read_text().splitlines() if line.startswith('Style: Default,'))
    extra_styles = '\n'.join(default_style.replace('Default,SubFont Test Fixture', f'{name},{font}')
        for name, font in [('CFF', 'SubFont CFF Fixture'), ('Second', 'SubFont Second Fixture')])
    styled.write_text(ass.read_text().replace('[Events]', extra_styles + '\n[Events]').replace('A{\\fnSubFont CFF Fixture}A, comma',
        'A😀{\\fnSubFont CFF Fixture}A{\\fnSubFont Second Fixture\\b1\\i1}A'), encoding='utf-8')
    run('-f', 'lavfi', '-i', 'color=c=black:s=320x180:r=1:d=1', '-i', styled,
        '-map', '0:v', '-map', '1:s', '-c:v', 'mpeg4', '-c:s', 'mov_text',
        '-movflags', 'frag_keyframe+empty_moov', fixtures / 'TimedTextStyled.mp4')
print('Generated embedded subtitle fixtures')
