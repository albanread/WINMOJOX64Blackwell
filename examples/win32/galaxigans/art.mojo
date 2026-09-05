"""Galaxigans' sprite art, converted from the BASIC original.

GENERATED. Regenerate with:

    python3 tools/galaxigans-art.py <the .bas> --mojo > examples/galaxigans/art.mojo

The conversion runs once and the result is committed, because it is art a
person can read and edit -- and because half of it was DRAWN in the original
with ellipses, triangles and filled circles into the definition's pixel
buffer, which `define_sprite` cannot take.

A digit is an index into the sprite's OWN sixteen colours and `.` is
transparent, exactly as the BASIC's own `SPRITE ROW` art was written.
"""

from gamepane.d3d11 import Sprites
from max.gpu.host import DeviceContext

comptime PLAYER = String(
    ".......11......./......1111....../......1111....../.....111111...../"
    ".....114411...../.....113311...../.....113311...../....21111112..../"
    "...2211111122.../..222211112222../.22222111122222./2222221111222222/"
    "2222221111222222/222..225522..222/.2....2552....2./.......66......."
)
comptime BEE = String(
    "................/................/................/........2......./"
    "......52225...../.....2222222..../....3.22222.3.../...33222222233../"
    "..3332222222333./.333322222223333/3444322222223444/.333322222223333/"
    "..3332222222333./...33222222233../....3...2...3.../................"
)
comptime BOSS = String(
    "............3.........../...........333........../.........3333333.."
    "....../........333333333......./......3333333333333...../.....332222"
    "222222233..../...3333222222222223333../..333332222222222233333./3333"
    "33322222522222333333/..333332222222222233333./...3333222222222223333"
    "../.....332222222222233..../......3222225222223...../......222222222"
    "2222...../......2222222222222...../......2222222222222...../......22"
    "44444444422...../........444444444......./........444444444......./."
    "......................."
)
comptime BULLET = String(
    ".11./.22./.22./.22./.33./.33./.44./.44."
)
comptime BOMB = String(
    "..2./.212/2111/.212/..2./..../..../...."
)
comptime STAR = String(
    "..../.1../..1./...."
)
comptime EXPLOSION_F0 = String(
    "......................../......................../.................."
    "....../......................../......................../..........."
    "............./......................../......................../...."
    "........4.........../..........44444........./.........4441444......"
    "../.........4411144......../........441111144......./.........441114"
    "4......../.........4441444......../..........44444........./........"
    "....4.........../......................../......................../."
    "......................./......................../..................."
    "...../......................../........................"
)
comptime EXPLOSION_F1 = String(
    "......................../......................../.................."
    "....../......................../............1.........../.........11"
    "11111......../.......11111111111....../......1111111111111...../...."
    "..1111114111111...../.....111114444411111..../.....111144444441111.."
    "../.....111144444441111..../....11114444444441111.../.....1111444444"
    "41111..../.....111144444441111..../.....111114444411111..../......11"
    "11114111111...../......1111111111111...../.......11111111111....../."
    "........1111111......../............1.........../..................."
    "...../......................../........................"
)
comptime EXPLOSION_F2 = String(
    "......................../......................../............2....."
    "....../........222222222......./......2222222222222...../.....222222"
    "222222222..../....22222222122222222.../....22222111111122222.../...2"
    "222211111111122222../...2222111111111112222../...2222111111111112222"
    "../...2222111111111112222../..222211111111111112222./...222211111111"
    "1112222../...2222111111111112222../...2222111111111112222../...22222"
    "11111111122222../....22222111111122222.../....22222222122222222.../."
    "....222222222222222..../......2222222222222...../........222222222.."
    "...../............2.........../........................"
)
comptime EXPLOSION_F3 = String(
    "......................../............2.........../........222232222."
    "....../......2222223222222...../.....222222333222222..../....2222222"
    "3332222222.../...2222222333332222222../...2222222333332222222../..22"
    "2222233333332222222./..222222333333333222222./..22223333333333333222"
    "2./..223333333222333333322./.23333333332223333333332/..2233333332223"
    "33333322./..222233333333333332222./..222222333333333222222./..222222"
    "233333332222222./...2222222333332222222../...2222222333332222222../."
    "...22222223332222222.../.....222222333222222..../......2222223222222"
    "...../........222232222......./............2..........."
)
comptime EXPLOSION_F4 = String(
    "............3.........../............2.........../........222222222."
    "....../......2222222222222...../....32222222222222223.../....2222222"
    "2222222222.../...2222222222222222222../...2222222222222222222../..22"
    "2222222222222222222./..222222222222222222222./..22222222222222222222"
    "2./..222222222222222222222./322222222222222222222232/..2222222222222"
    "22222222./..222222222222222222222./..222222222222222222222./..222222"
    "222222222222222./...2222222222222222222../...2222222222222222222../."
    "...22222222222222222.../....32222222222222223.../......2222222222222"
    "...../........222222222......./............2..........."
)
comptime EXPLOSION_F5 = String(
    "......................../......................../.................."
    "....../...3.................3../......................../..........."
    "............./......................../......................../...."
    "..................../......................../......................"
    "../......................../......................../..............."
    "........./......................../......................../........"
    "................/......................../......................../."
    "......................./......................../...3..............."
    "..3../......................../........................"
)
comptime SAUCER = String(
    "................................/................................/.."
    "............................../................5.............../...."
    "....33322555555522333......./.....33332225555555552223333..../....33"
    "33222225555555222223333.../...333333222222252222222333333../..111111"
    "11111111111111111111111./...333333333333323333333333333../....333333"
    "3333333333333333333.../.....34333333333433333333343..../........3333"
    "3333333333333......./................3..............."
)
comptime BUTTERFLY = String(
    "2..............2/22......5.....22/2222...555..2222/2222225555522222/"
    "2224222252224222/222222.353.22222/2222...333..2222/22.....333....22/"
    "2......333.....2/2222...333..2222/2222222232222222/222222.333.22222/"
    "22222..333..2222/222....333...222/22.....333....22/2..............2"
)
comptime SCORPION_F0 = String(
    ".....33........./....3333......../...222222......./..22222222....../"
    ".2222222222...../.2222222222...../.2222222222...../..2222222222..../"
    ".4422222244...../444422224444..../444422224444..../.44.2222.44...../"
    "...322223......./..333..333....../................/................"
)
comptime SCORPION_F1 = String(
    ".....33........./....3333......../...222222......./..22222222....../"
    ".2222222222...../.2222222222...../.2222222222...../..2222222222..../"
    "44.222222.44..../44..2222..44..../44..2222..44..../.44.2222.44...../"
    "...322223......./..333..333....../................/................"
)
comptime BLUE_BEE_F0 = String(
    "................/................/33333.......3333/.3333...4...3333/"
    "..333.54445.333./..3334444444333./...33.44444.33../....322242223.../"
    "....322222223.../....222222222.../...22222222222../....222222222.../"
    "....222222222.../.....2222222..../........2......./................"
)
comptime BLUE_BEE_F1 = String(
    "................/................/3.............../........4......./"
    "......54445...../.....4444444..../......44444...../.....2224222..../"
    "....222222222.../....222222222.../...23222222232../...33222222233../"
    "..3332222222333./.333322222223333/33333...2...3333/................"
)
comptime MOTH_F0 = String(
    "3.............../.3.............3/.33...........33/.333.........333/"
    ".3533.42242.3533/..3333222223333./..3333322233333./..333.22222.333./"
    "..3...22222...3./......22222...../......22222...../......22222...../"
    "......22222...../......22222...../......22222...../................"
)
comptime MOTH_F1 = String(
    "3.............../................/................/................/"
    "......42242...../......22222...../3.....22222...../3333..22222..333/"
    "3353333222333533/3333..22222..333/3.....22222...../......22222...../"
    "......22222...../......22222...../......22222...../................"
)
comptime MOTH_F2 = String(
    "................/................/................/................/"
    "......42242...../......22222...../3.....22222...../3.....22222...../"
    "3.3...22222...3./3.333.22222.333./3.3333322233333./..3333222223333./"
    ".3533.22222.3533/.333..22222..333/.33...22222...33/.3.............3"
)


def define_all(mut sprites: Sprites) raises -> List[Int]:
    """Every definition and its palette, in the BASIC's own order. The
    returned handles are indexed by the *_SLOT constants below."""
    var ids = List[Int]()

    # PLAYER -- 16x16, 1 frame
    let player_ID = sprites.define_sprite(PLAYER)
    sprites.sprite_rgb(player_ID, 1, 255, 255, 255)
    sprites.sprite_rgb(player_ID, 2, 220, 20, 20)
    sprites.sprite_rgb(player_ID, 3, 20, 60, 220)
    sprites.sprite_rgb(player_ID, 4, 0, 255, 255)
    sprites.sprite_rgb(player_ID, 5, 100, 100, 100)
    sprites.sprite_rgb(player_ID, 6, 255, 200, 0)
    ids.append(player_ID)

    # BEE -- 16x16, 1 frame
    let bee_ID = sprites.define_sprite(BEE)
    sprites.sprite_rgb(bee_ID, 1, 0, 0, 0)
    sprites.sprite_rgb(bee_ID, 2, 255, 230, 0)
    sprites.sprite_rgb(bee_ID, 3, 220, 60, 60)
    sprites.sprite_rgb(bee_ID, 4, 255, 255, 255)
    sprites.sprite_rgb(bee_ID, 5, 80, 200, 255)
    ids.append(bee_ID)

    # BOSS -- 24x20, 1 frame
    let boss_ID = sprites.define_sprite(BOSS)
    sprites.sprite_rgb(boss_ID, 1, 0, 0, 0)
    sprites.sprite_rgb(boss_ID, 2, 60, 220, 60)
    sprites.sprite_rgb(boss_ID, 3, 180, 60, 180)
    sprites.sprite_rgb(boss_ID, 4, 80, 80, 120)
    sprites.sprite_rgb(boss_ID, 5, 255, 80, 255)
    ids.append(boss_ID)

    # BULLET -- 4x8, 1 frame
    let bullet_ID = sprites.define_sprite(BULLET)
    sprites.sprite_rgb(bullet_ID, 1, 255, 255, 255)
    sprites.sprite_rgb(bullet_ID, 2, 255, 255, 0)
    sprites.sprite_rgb(bullet_ID, 3, 255, 128, 0)
    sprites.sprite_rgb(bullet_ID, 4, 255, 0, 0)
    ids.append(bullet_ID)

    # BOMB -- 4x8, 1 frame
    let bomb_ID = sprites.define_sprite(BOMB)
    sprites.sprite_rgb(bomb_ID, 1, 255, 120, 0)
    sprites.sprite_rgb(bomb_ID, 2, 255, 60, 60)
    ids.append(bomb_ID)

    # STAR -- 4x4, 1 frame
    let star_ID = sprites.define_sprite(STAR)
    sprites.sprite_rgb(star_ID, 1, 200, 200, 255)
    ids.append(star_ID)

    # EXPLOSION -- 24x24, 6 frames
    let explosion_ID = sprites.define_sprite(EXPLOSION_F0)
    _ = sprites.add_frame(explosion_ID, EXPLOSION_F1)
    _ = sprites.add_frame(explosion_ID, EXPLOSION_F2)
    _ = sprites.add_frame(explosion_ID, EXPLOSION_F3)
    _ = sprites.add_frame(explosion_ID, EXPLOSION_F4)
    _ = sprites.add_frame(explosion_ID, EXPLOSION_F5)
    sprites.sprite_rgb(explosion_ID, 1, 255, 255, 0)
    sprites.sprite_rgb(explosion_ID, 2, 255, 120, 0)
    sprites.sprite_rgb(explosion_ID, 3, 200, 50, 50)
    sprites.sprite_rgb(explosion_ID, 4, 255, 255, 255)
    ids.append(explosion_ID)

    # SAUCER -- 32x14, 1 frame
    let saucer_ID = sprites.define_sprite(SAUCER)
    sprites.sprite_rgb(saucer_ID, 1, 20, 20, 20)
    sprites.sprite_rgb(saucer_ID, 2, 200, 200, 255)
    sprites.sprite_rgb(saucer_ID, 3, 120, 150, 255)
    sprites.sprite_rgb(saucer_ID, 4, 255, 120, 60)
    sprites.sprite_rgb(saucer_ID, 5, 255, 255, 255)
    ids.append(saucer_ID)

    # BUTTERFLY -- 16x16, 1 frame
    let butterfly_ID = sprites.define_sprite(BUTTERFLY)
    sprites.sprite_rgb(butterfly_ID, 1, 0, 0, 0)
    sprites.sprite_rgb(butterfly_ID, 2, 220, 60, 220)
    sprites.sprite_rgb(butterfly_ID, 3, 255, 255, 255)
    sprites.sprite_rgb(butterfly_ID, 4, 0, 255, 255)
    sprites.sprite_rgb(butterfly_ID, 5, 255, 120, 60)
    ids.append(butterfly_ID)

    # SCORPION -- 16x16, 2 frames
    let scorpion_ID = sprites.define_sprite(SCORPION_F0)
    _ = sprites.add_frame(scorpion_ID, SCORPION_F1)
    sprites.sprite_rgb(scorpion_ID, 1, 0, 0, 0)
    sprites.sprite_rgb(scorpion_ID, 2, 220, 0, 0)
    sprites.sprite_rgb(scorpion_ID, 3, 255, 255, 0)
    sprites.sprite_rgb(scorpion_ID, 4, 120, 120, 120)
    ids.append(scorpion_ID)

    # BLUE_BEE -- 16x16, 2 frames
    let blue_bee_ID = sprites.define_sprite(BLUE_BEE_F0)
    _ = sprites.add_frame(blue_bee_ID, BLUE_BEE_F1)
    sprites.sprite_rgb(blue_bee_ID, 1, 0, 0, 0)
    sprites.sprite_rgb(blue_bee_ID, 2, 60, 100, 255)
    sprites.sprite_rgb(blue_bee_ID, 3, 255, 230, 0)
    sprites.sprite_rgb(blue_bee_ID, 4, 150, 200, 255)
    sprites.sprite_rgb(blue_bee_ID, 5, 220, 0, 0)
    ids.append(blue_bee_ID)

    # MOTH -- 16x16, 3 frames
    let moth_ID = sprites.define_sprite(MOTH_F0)
    _ = sprites.add_frame(moth_ID, MOTH_F1)
    _ = sprites.add_frame(moth_ID, MOTH_F2)
    sprites.sprite_rgb(moth_ID, 1, 0, 0, 0)
    sprites.sprite_rgb(moth_ID, 2, 180, 180, 180)
    sprites.sprite_rgb(moth_ID, 3, 100, 255, 100)
    sprites.sprite_rgb(moth_ID, 4, 255, 255, 255)
    sprites.sprite_rgb(moth_ID, 5, 255, 0, 255)
    ids.append(moth_ID)
    return ids^


# Where each definition sits in the list `define_all` returns.
comptime PLAYER_SLOT = 0
comptime BEE_SLOT = 1
comptime BOSS_SLOT = 2
comptime BULLET_SLOT = 3
comptime BOMB_SLOT = 4
comptime STAR_SLOT = 5
comptime EXPLOSION_SLOT = 6
comptime SAUCER_SLOT = 7
comptime BUTTERFLY_SLOT = 8
comptime SCORPION_SLOT = 9
comptime BLUE_BEE_SLOT = 10
comptime MOTH_SLOT = 11

# Frame sizes, for collision boxes and placement.
comptime PLAYER_W = 16
comptime PLAYER_H = 16
comptime BEE_W = 16
comptime BEE_H = 16
comptime BOSS_W = 24
comptime BOSS_H = 20
comptime BULLET_W = 4
comptime BULLET_H = 8
comptime BOMB_W = 4
comptime BOMB_H = 8
comptime STAR_W = 4
comptime STAR_H = 4
comptime EXPLOSION_W = 24
comptime EXPLOSION_H = 24
comptime SAUCER_W = 32
comptime SAUCER_H = 14
comptime BUTTERFLY_W = 16
comptime BUTTERFLY_H = 16
comptime SCORPION_W = 16
comptime SCORPION_H = 16
comptime BLUE_BEE_W = 16
comptime BLUE_BEE_H = 16
comptime MOTH_W = 16
comptime MOTH_H = 16
