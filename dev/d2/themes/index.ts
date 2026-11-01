import {presentationThemeLayers,type ThemeLayers} from '@deterministic-engineering/render/presentation-theme';
/** Project display overrides extend published Library themes; no drawing engine. */
export const themes:ThemeLayers={...presentationThemeLayers,reading:{typography:{titleSize:"25px",detailSize:"24px",pageTitleSize:"42px",pageQuestionSize:"27px",headingSize:"24px",bodySize:"25px",noteSize:"22px",eyebrowSize:"17px",subtitleSize:"23px"},spacing:{iconSize:34,iconGap:14},stylesheet:'.scene-title{font-size:25px}.scene-detail{font-size:24px}.scene-group-title{font-size:24px}'}};
