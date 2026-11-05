// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

import {presentationThemeLayers,type ThemeLayers} from '@deterministic-engineering/render/presentation-theme';
/** Project display overrides extend published Library themes; no drawing engine. */
export const themes:ThemeLayers={...presentationThemeLayers,reading:{typography:{titleSize:"26px",detailSize:"26px",labelSize:"26px",pageTitleSize:"36px",pageQuestionSize:"26px",headingSize:"24px",bodySize:"25px",noteSize:"26px",eyebrowSize:"17px",subtitleSize:"23px"},spacing:{iconSize:34,iconGap:14,gap:14},stylesheet:'.scene-title{font-size:26px}.scene-detail{font-size:26px}.scene-group-title{font-size:26px}'},
 'workflow-labels':{typography:{labelSize:'24px'}},
 'sequence-reading':{
  typography:{pageTitleSize:'54px',pageQuestionSize:'36px'},
  spacing:{gap:18},
  colors:{background:'#F8FAFC',surface:'#FFFFFF',ink:'#18314B',muted:'#63758A',border:'#D8E2ED',accent:'#315F91',tint:'#EAF0F7'},
 }
};
