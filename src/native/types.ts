export type FilterStatus =
  | {kind: 'active'; label: string}
  | {kind: 'inactive'; label: string}
  | {kind: 'checking'; label: string}
  | {kind: 'error'; label: string};

export type ICloudStatus =
  | {kind: 'available'; label: string}
  | {kind: 'unavailable'; label: string}
  | {kind: 'checking'; label: string};

export type StatusViewModel = {
  filter: FilterStatus;
  icloud: ICloudStatus;
};
