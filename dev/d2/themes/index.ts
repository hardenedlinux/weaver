import {presentationThemeLayers,type ThemeLayers} from '@deterministic-engineering/render/presentation-theme';
/** Project display overrides extend published Library themes; no drawing engine. */
export const themes:ThemeLayers={...presentationThemeLayers,reading:{stylesheet:'.scene-title{font-size:25px}.scene-detail{font-size:22px}.scene-group-title{font-size:24px}'}};
